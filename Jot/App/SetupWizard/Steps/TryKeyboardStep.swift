//
//  TryKeyboardStep.swift
//  Jot
//
//  Wizard panel W5 — "Now try the keyboard".
//
//  The hands-on "try it" step. The user taps the practice field (glowing),
//  the Jot keyboard rises, they tap "Jot down" in the keyboard, speak, and
//  tap Stop — Jot pastes their words into the field. Then they tap Continue
//  themselves (NO auto-advance).
//
//  App / extension split (per the design handoff §22-24): the streaming pane,
//  the "First-time setup" koan pane, and the transport (Jot down / Stop pill)
//  all live in the REAL keyboard extension — they are the system keyboard, not
//  redrawn here. This SwiftUI step renders only the WIZARD chrome the handoff
//  assigns to the containing app: the title, the per-state instruction, the
//  practice field, the phrase helper, and the footer CTA. The wizard-visible
//  micro-states it can drive are therefore `invite → rise → done`:
//
//    • invite — glowing practice field + "Try saying …" helper, CTA "I tried it".
//    • rise   — field tapped → keyboard summoned, field empty with caret, glow
//               gone, phrase helper. The keyboard's own panes (idle "Tap Jot
//               down" → First-time-setup koan → streaming → Stop-glows) play out
//               here; the wizard field stays EMPTY until the paste lands.
//    • done   — the finalized dictation landed (the keyboard pasted it into the
//               field): field FILLED, helper "Pasted from Jot ✓", CTA "Continue"
//               which the user taps themselves. No auto-advance.
//
//  Koan gate: while this step is on screen we set `AppGroup.wizardActive`, which
//  routes `ColdStartCopy.beginningLine()` to the one-time "First-time setup"
//  koan — ONLY here. It's cleared on leave so the keyboard / hero only ever
//  show the rotating lines.
//

import SwiftUI
import os.log

private let tryKeyboardLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot",
    category: "setup-wizard.W5"
)

struct TryKeyboardStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    @Environment(RecordingService.self) private var recordingService
    @Environment(StreamingPartial.self) private var streamingPartial
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wizard-visible micro-state. The keyboard-internal `init`/`stream`/`stop`
    /// panes play out while we sit in `.rise`; we flip to `.done` only when the
    /// finalized dictation pastes into the field.
    private enum Phase: Equatable {
        case invite   // glowing field, inviting the first tap
        case rise     // keyboard up, capturing — field empty
        case done     // result pasted, success + manual Continue
    }

    @State private var phase: Phase = .invite
    @State private var enteredAt: Date = Date()
    @State private var fieldText: String = ""
    @State private var pollTask: Task<Void, Never>?

    /// Whether the Jot keyboard is currently the frontmost keyboard, polled
    /// from `AppGroup.isJotKeyboardActive()`. While in `.rise` and this is
    /// `false`, the system keyboard is still up — we show the globe-switch cue.
    @State private var jotKeyboardActive = false
    /// Set ~6s into `.rise` while the Jot keyboard is still NOT active — raises
    /// the cue to stage 2 ("It's the bottom-left key"). Reset whenever the
    /// keyboard becomes active or the phase leaves `.rise`.
    @State private var globeHintEscalated = false
    /// Polls keyboard-active state (~0.5s) to drive the globe-switch cue.
    @State private var keyboardActivePollTask: Task<Void, Never>?
    /// Wall-clock when `.rise` was entered — escalation is measured from here.
    @State private var riseEnteredAt: Date?

    /// A fixed phrase nudge chosen once per entry (random from the set), so the
    /// helper line is stable while the user reads it rather than flickering.
    @State private var suggestion: String = TryKeyboardStep.suggestions.randomElement() ?? "I am awesome."

    /// Drives the breathing invite glow + sheen on the practice field.
    @State private var glowPulse = false

    @FocusState private var fieldFocused: Bool

    /// Phrase nudges — what to say if you're stuck (handoff §106-116).
    private static let suggestions = [
        "I am awesome.",
        "I believe in myself.",
        "Today is going to be a good day.",
        "I’ve got this.",
        "Hello from my new keyboard.",
    ]

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 4), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 0) {
                Spacer(minLength: 24)

                WizardItalicTitle(text: "Now try the keyboard", size: 28)
                    .accessibilityAddTraits(.isHeader)

                Spacer().frame(height: 14)

                instruction
                    .frame(maxWidth: 330)

                Spacer().frame(height: 26)

                practiceField

                Spacer().frame(height: 16)

                helper

                Spacer(minLength: 8)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: phase)
        } footer: {
            // Once the user taps the field and the dictation flow is underway
            // (`.rise`), hide the advance button so they complete the loop rather
            // than skip — it returns as "Continue" on success (`.done`). Shown in
            // `.invite` as the pre-try skip.
            if phase != .rise {
                WizardPrimaryButton(
                    title: phase == .done ? "Continue" : "I tried it",
                    action: onAdvance
                )
            }
        }
        .task {
            enteredAt = Date()
            // Set the koan gate so the keyboard's First-time-setup pane shows
            // the one-time line ONLY while this step is up.
            AppGroup.wizardActive = true
            startPolling()
            startKeyboardActivePolling()
            if !reduceMotion {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    glowPulse = true
                }
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            // First tap on the (glowing) practice field summons the Jot keyboard
            // and advances invite → rise. We never auto-record here — the user
            // taps "Jot down" in the keyboard itself (guided, one action at a
            // time). Don't regress out of `done` if the field re-focuses.
            if focused && phase == .invite {
                riseEnteredAt = Date()
                globeHintEscalated = false
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                    phase = .rise
                }
            }
        }
        .onChange(of: phase) { _, newPhase in
            // Leaving `.rise` (to `.done`) clears any escalation and the rise
            // timestamp so a future re-entry starts the cue from stage 1.
            if newPhase != .rise {
                globeHintEscalated = false
                riseEnteredAt = nil
            }
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
            keyboardActivePollTask?.cancel()
            keyboardActivePollTask = nil
            // Clear the koan gate — leaving this step must never leak the
            // one-time line into the keyboard / hero.
            AppGroup.wizardActive = false
            tearDownRecordingIfNeeded()
        }
    }

    // MARK: - Per-state instruction

    @ViewBuilder
    private var instruction: some View {
        switch phase {
        case .invite:
            WizardBody(text: "Tap the field below, switch to Jot via the globe key, then tap Jot down.")
        case .rise:
            // All in-`.rise` guidance now lives INSIDE the practice field (see
            // `inFieldCue`), so the subtitle holds layout with an empty spacer
            // sized to the one-line instruction height — no double-messaging.
            Color.clear.frame(height: 22)
        case .done:
            WizardBody(text: "That’s the whole loop — your words landed in the field.")
        }
    }

    // MARK: - Practice field

    private var practiceField: some View {
        let glowing = phase == .invite

        return ZStack(alignment: .topLeading) {
            // Real, focusable field: tapping it raises the Jot keyboard, and the
            // keyboard inserts the dictated text directly into it on Stop. We
            // bind `fieldText` so the `done` state can also display the pasted
            // result if the in-process insert hasn't already populated it.
            TextField("", text: $fieldText, axis: .vertical)
                .lineLimit(3, reservesSpace: true)
                .font(.system(size: 16.5, weight: .regular))
                .foregroundStyle(Color.jotInk)
                .tint(Color.jotAccent)
                .focused($fieldFocused)
                .disabled(phase == .done)

            // Placeholder overlay — accent "Tap to try it" while glowing,
            // hidden once the user has interacted or text is present.
            if glowing && fieldText.isEmpty {
                Text("Tap to try it")
                    .font(.system(size: 16.5, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                    .allowsHitTesting(false)
            }

            // In-field progressive cue — the single guidance surface for the
            // whole `.rise` loop (switch keyboard → tap Jot down → say
            // something). The real TextField stays underneath, keeping the
            // keyboard raised; this is a non-interactive overlay.
            inFieldCue
                .allowsHitTesting(false)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(
            .ultraThinMaterial,
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    glowing ? Color.jotAccent : Color.jotInk.opacity(0.12),
                    lineWidth: 1.5
                )
        )
        // Breathing invite glow ring (handoff: `0 0 0 4px a.soft`, 2.2s) — only
        // while glowing, and only when Reduce Motion is off.
        .shadow(
            color: glowing ? Color.jotAccent.opacity(glowPulse && !reduceMotion ? 0.30 : 0.14) : .clear,
            radius: glowing ? (glowPulse && !reduceMotion ? 10 : 5) : 0
        )
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: glowing)
        .accessibilityLabel("Practice field")
        .accessibilityHint(phase == .done
            ? "Your dictated text was pasted here."
            : "Tap to raise the Jot keyboard and try dictation.")
    }

    // MARK: - In-field progressive cue (states 2–4)

    /// The guidance state shown INSIDE the practice field while in `.rise`. The
    /// cue walks the user through the whole loop in one place rather than
    /// scattering overlays through the ZStack. `nil` (state 1 placeholder, and
    /// state 5 once live text is present or `.done`) renders nothing.
    private enum CueState: Equatable {
        case switchKeyboard   // system keyboard still up → tap the globe
        case tapJotDown       // Jot keyboard up, not recording yet
        case saySomething     // recording, nothing captured yet
    }

    /// Pure mapping from phase / keyboard-active / recording / captured-text to
    /// the in-field cue. Keeping the whole progression in one switch is the
    /// "single coherent structure" the cue is supposed to be.
    private var cueState: CueState? {
        guard phase == .rise else { return nil }
        // Text is already in the field (dictated + pasted, or typed) → show the
        // text, never a cue over it. THIS is the fix for "Tap Jot down" (and any
        // cue) reappearing on top of the dictated result after Stop.
        if !fieldText.isEmpty { return nil }
        if !jotKeyboardActive { return .switchKeyboard }
        // Actively recording: prompt to speak only until live text starts arriving.
        // (Caveat: with live-text OFF, `streamingText` stays empty, so this cue
        // persists until Stop — an acceptable fallback.)
        if recordingService.isRecording {
            return streamingPartial.streamingText.isEmpty ? .saySomething : nil
        }
        // Stopped, transcript still transcribing/landing → no cue, so "Tap Jot
        // down" never flashes over the incoming result during the stop→paste gap.
        if recordingService.isPipelineInFlight { return nil }
        // Jot keyboard up, idle, nothing dictated yet → tap Jot down.
        return .tapJotDown
    }

    @ViewBuilder
    private var inFieldCue: some View {
        switch cueState {
        case .switchKeyboard:
            // Purely about switching the KEYBOARD — never implies the Jot app
            // isn't running.
            globeSwitchCue
        case .tapJotDown:
            // Glyph + accent text, mirroring the globe cue's stage-1 row.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                Text("Tap Jot down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Tap Jot down")
        case .saySomething:
            // The phrase prompt that used to live in the subtitle — same
            // styling, now inside the box. Example phrase in Fraunces italic,
            // the rest in the body sans.
            (
                Text("Say something out loud — like ")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundColor(Color.jotPageInkSecondary)
                + Text("“I am awesome.”")
                    .font(.custom(JotType.frauncesItalicText, size: 16))
                    .foregroundColor(Color.jotPageInk)
            )
            .multilineTextAlignment(.leading)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .none:
            EmptyView()
        }
    }

    // MARK: - Globe-switch cue (in-field, two-stage)

    /// The progressive "switch to the Jot keyboard" cue rendered inside the
    /// practice field. Stage 1 (always when shown) tells the user to tap the
    /// globe; stage 2 (after ~6s with the system keyboard still up) adds where
    /// the globe is. NEVER implies the Jot app isn't running — it's purely
    /// about switching the keyboard.
    @ViewBuilder
    private var globeSwitchCue: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Stage 1 — tap the globe.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                Text("Tap the globe to switch to Jot keyboard")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Stage 2 — where the globe is. Fades in after escalation.
            if globeHintEscalated {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Color.jotPageInkSecondary)
                    Text("It’s the bottom-left key")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: globeHintEscalated)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(globeHintEscalated
            ? "Tap the globe to switch to Jot keyboard. It’s the bottom-left key."
            : "Tap the globe to switch to Jot keyboard")
    }

    // MARK: - Helper line (phrase nudge / success)

    @ViewBuilder
    private var helper: some View {
        switch phase {
        case .invite:
            // "Try saying “…”" — "Try saying" muted sans, phrase Fraunces italic.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Try saying")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(Color.jotMute)
                Text("“\(suggestion)”")
                    .font(.custom(JotType.frauncesItalicText, size: 16))
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
            .frame(height: 24)
            .accessibilityElement(children: .combine)
        case .rise:
            // No phrase nudge here — the instruction above already gives the
            // example ("Say something out loud — like 'I am awesome.'"), so a
            // second "Try saying …" below the field is redundant (owner). Empty
            // spacer keeps the layout stable across the invite→rise transition.
            Color.clear.frame(height: 24)
        case .done:
            // Success moment — "Pasted from Jot ✓" with a small accent check.
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.jotAccent)
                Text("Pasted from Jot")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
            }
            .frame(height: 24)
            .transition(.opacity)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Pasted from Jot")
        }
    }

    // MARK: - Final-dictation detection (success trigger, NOT auto-advance)

    /// Watch for a finalized dictation newer than this step's entry. When it
    /// lands we flip to the `done` success state — we do NOT call `onAdvance()`
    /// (no auto-advance; the user taps Continue themselves).
    private func startPolling() {
        pollTask?.cancel()
        let entryTime = enteredAt
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                if let fresh = ClipboardHandoff.readFresh(),
                   fresh.timestamp > entryTime,
                   !fresh.text.isEmpty {
                    // Fill the field with the result if the in-process insert
                    // didn't already land there, then settle into success.
                    if fieldText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        fieldText = fresh.text
                    }
                    fieldFocused = false
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        phase = .done
                    }
                    tryKeyboardLog.notice("W5 dictation landed — success state (manual Continue, no auto-advance)")
                    return
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }

    // MARK: - Keyboard-active polling (globe-switch cue gate)

    /// Poll `AppGroup.isJotKeyboardActive()` every ~0.5s. Drives:
    ///   • `jotKeyboardActive` — gates the in-field globe cue (shown only in
    ///     `.rise` while the Jot keyboard is NOT yet frontmost).
    ///   • `globeHintEscalated` — when in `.rise` and still not active ~6s
    ///     after rise, escalate to stage 2 ("It's the bottom-left key").
    ///     Reset the instant the keyboard becomes active.
    private func startKeyboardActivePolling() {
        keyboardActivePollTask?.cancel()
        keyboardActivePollTask = Task { @MainActor in
            while !Task.isCancelled {
                let active = AppGroup.isJotKeyboardActive()
                if active != jotKeyboardActive {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        jotKeyboardActive = active
                    }
                }
                if active {
                    // Keyboard switched to Jot — drop any escalation.
                    if globeHintEscalated { globeHintEscalated = false }
                } else if phase == .rise, let riseAt = riseEnteredAt,
                          Date().timeIntervalSince(riseAt) >= 6.0,
                          !globeHintEscalated {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        globeHintEscalated = true
                    }
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    // MARK: - Gentle teardown (wizard contract, honours warm-hold)

    /// Release any W5 recording before the step leaves. Per the project rule we
    /// NEVER `forceStop()`/`discard()` the mic — we use the gentle `cancel()`,
    /// which discards the Jot-internal (never-saved) W5 audio AND honours Warm
    /// Hold. Entering/re-entering the step does NOT run this — only leaving does
    /// — so an in-progress capture is never killed on entry.
    private func tearDownRecordingIfNeeded() {
        let service = recordingService
        let gentleStop: @MainActor () -> Void = {
            tryKeyboardLog.notice("W5 leaving while recording in flight — gently cancelling (honours warm-hold)")
            if service.isRecording {
                Task { @MainActor in await service.cancel() }
            }
            // Stop already tapped, pipeline still transcribing: `cancel()` would
            // no-op (no active slice), so clear the pipeline state decisively
            // (avoid a stuck in-flight flag / missing `.idle` on the home view).
            if service.isPipelineInFlight {
                service.markPipelineFinished()
                service.publishPipelinePhase(.idle)
            }
        }
        if service.isRecording || service.isPipelineInFlight {
            gentleStop()
        } else {
            // Dismiss-during-start race: `start()` is fired from the wizard
            // host's keyboard-tap handler in an untracked Task. If the user
            // leaves mid-`start()`, `isRecording`/`isPipelineInFlight` haven't
            // flipped yet, so the synchronous check above misses it and the mic
            // comes up after the step is gone. Watch briefly for a late flip and
            // reap — gently.
            Task { @MainActor in
                let deadline = Date().addingTimeInterval(2.0)
                while Date() < deadline {
                    if service.isRecording || service.isPipelineInFlight {
                        gentleStop()
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
    }
}
