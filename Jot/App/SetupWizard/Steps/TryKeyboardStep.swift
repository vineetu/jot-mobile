//
//  TryKeyboardStep.swift
//  Jot
//
//  Phase 6 — wizard panel W6.
//  "Now try the keyboard" — passive verification. Auto-advances when a
//  fresh `ClipboardHandoff.FreshDictation` newer than this step's entry
//  timestamp lands in the App Group. Provides a manual "I've got it"
//  affordance so the user can skip forward if detection misses.
//

import SwiftUI
import os.log

private let tryKeyboardLog = Logger(
    subsystem: "com.vineetu.jot.mobile.Jot",
    category: "setup-wizard.W6"
)

struct TryKeyboardStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    @Environment(RecordingService.self) private var recordingService

    @State private var enteredAt: Date = Date()
    @State private var detectedFreshDictation = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 5), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 16) {
                Spacer(minLength: 16)

                WizardItalicTitle(text: "Now try the keyboard", size: 28)
                    .padding(.bottom, 4)

                WizardBody(text: "Tap the field below, switch to Jot via the globe key, then tap Dictate.")

                sampleField
                    .padding(.top, 12)

                Text(detectedFreshDictation ? "Got it — we saw your dictation." : "Listening for your text…")
                    .font(.custom(JotType.frauncesItalicText, size: 12))
                    .foregroundStyle(detectedFreshDictation ? Color.jotSuccessInk : Color.jotMute)
                    .padding(.top, 6)

                Spacer(minLength: 8)
            }
        } footer: {
            WizardPrimaryButton(
                title: detectedFreshDictation ? "Continue" : "I tried it",
                action: onAdvance
            )
        }
        .task {
            enteredAt = Date()
            startPolling()
        }
        .onDisappear {
            pollTask?.cancel()
            pollTask = nil
            let service = recordingService
            let teardown: @MainActor () -> Void = {
                tryKeyboardLog.notice("W6 disappearing while recording in flight — force-stopping (wizard contract)")
                service.forceStop()
                service.markPipelineFinished()
                service.publishPipelinePhase(.idle)
            }
            if service.isRecording || service.isPipelineInFlight {
                teardown()
            } else {
                // Dismiss-during-start race: W6's `start()` is fired
                // from the wizard host's keyboard-tap handler in an
                // untracked Task. If the user dismisses mid-`start()`,
                // `isRecording`/`isPipelineInFlight` haven't flipped
                // yet, so the synchronous check above misses it and the
                // mic comes up after the wizard is gone. Watch briefly
                // for a late flip and reap.
                Task { @MainActor in
                    let deadline = Date().addingTimeInterval(2.0)
                    while Date() < deadline {
                        if service.isRecording || service.isPipelineInFlight {
                            teardown()
                            return
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        }
    }

    // MARK: - Sample text field

    private var sampleField: some View {
        TextField("Tap here, then switch to the Jot keyboard…", text: .constant(""), axis: .vertical)
            .lineLimit(3, reservesSpace: true)
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(Color.jotInk)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.jotAccent.opacity(0.4), lineWidth: 2)
            )
            .frame(minHeight: 76)
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        let entryTime = enteredAt
        pollTask = Task { @MainActor in
            // 750ms cadence — fast enough to feel snappy when the user
            // returns from the keyboard, slow enough to avoid contending
            // with the main app's normal work.
            while !Task.isCancelled {
                if let fresh = ClipboardHandoff.readFresh(),
                   fresh.timestamp > entryTime,
                   !fresh.text.isEmpty {
                    detectedFreshDictation = true
                    // Brief beat so the user sees the "Got it" copy before
                    // auto-advancing.
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    guard !Task.isCancelled else { return }
                    onAdvance()
                    return
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }
}
