//
//  TryKeyboardStep.swift
//  Jot
//
//  Phase 6 — wizard panel W8.
//  "Now try the keyboard" — passive verification. Auto-advances when a
//  fresh `ClipboardHandoff.FreshDictation` newer than this step's entry
//  timestamp lands in the App Group. Provides a manual "I've got it"
//  affordance so the user can skip forward if detection misses.
//

import SwiftUI

struct TryKeyboardStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    @State private var enteredAt: Date = Date()
    @State private var detectedFreshDictation = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 7), onClose: onClose)
        ) {
            VStack(spacing: 16) {
                Spacer(minLength: 16)

                WizardTitle(text: "Now try the keyboard", size: 26)
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
                    onAdvance()
                    return
                }
                try? await Task.sleep(nanoseconds: 750_000_000)
            }
        }
    }
}
