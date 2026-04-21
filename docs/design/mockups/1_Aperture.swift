// Aperture — “Voice Memos native+”
//
// The direction Apple would ship if dictation were a first-party iOS app.
// Single surface, one primary affordance, hairline level meter around a
// circular mic button, SF Rounded numerals for elapsed time, semantic
// colors throughout. No branded anything — Jot borrows Apple's language.
//
// Drop into Xcode → Preview. Self-contained. No production services.

import SwiftUI

struct ApertureMockup: View {
    @State private var phase: Phase = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var amplitude: CGFloat = 0.2
    @State private var transcript: String = ""
    @State private var timer: Timer?

    enum Phase { case idle, recording, transcribing, done }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                timeDisplay
                micWithRing
                statusCaption
                transcriptPane
                Spacer(minLength: 0)
                actionsRow
                    .opacity(phase == .done ? 1 : 0.35)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .navigationTitle("Jot")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { } label: { Image(systemName: "gear") }
                        .accessibilityLabel("Settings")
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Elements

    private var timeDisplay: some View {
        Text(timeString)
            .font(.system(size: 56, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .foregroundStyle(phase == .recording ? Color.red : .primary)
            .animation(.snappy, value: phase)
    }

    private var micWithRing: some View {
        ZStack {
            // Outer hairline ring — the quiet shell.
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                .frame(width: 220, height: 220)

            // Level-meter arc.
            Circle()
                .trim(from: 0, to: min(1, max(0.02, amplitude)))
                .stroke(
                    phase == .recording ? Color.red : Color.accentColor,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 220, height: 220)
                .animation(.easeOut(duration: 0.12), value: amplitude)

            // The button itself — inner core.
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(.background)
                        .frame(width: 176, height: 176)
                        .shadow(color: .black.opacity(0.06), radius: 16, y: 6)
                    Circle()
                        .fill(phase == .recording ? Color.red : Color.accentColor)
                        .frame(width: 148, height: 148)
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .scaleEffect(phase == .recording ? 0.97 : 1)
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: phase)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(phase == .recording ? "Stop recording" : "Start recording")
        }
    }

    private var statusCaption: some View {
        Text(statusText)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(1.6)
            .frame(maxWidth: .infinity)
    }

    private var transcriptPane: some View {
        Group {
            if transcript.isEmpty {
                HStack {
                    Text("Your words will appear here.")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            } else {
                ScrollView {
                    Text(transcript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 220, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private var actionsRow: some View {
        HStack(spacing: 12) {
            Button {} label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Button {} label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private var timeString: String {
        let s = Int(elapsed) % 60
        let m = Int(elapsed) / 60
        return String(format: "%02d:%02d", m, s)
    }

    private var statusText: String {
        switch phase {
        case .idle: return "Tap to dictate"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case .done: return "Copied to clipboard"
        }
    }

    private func toggle() {
        switch phase {
        case .idle, .done:
            phase = .recording
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                elapsed += 0.1
                amplitude = CGFloat.random(in: 0.15...0.95)
            }
        case .recording:
            timer?.invalidate()
            phase = .transcribing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                transcript = "Testing the Aperture mockup — a quiet surface borrowed from Voice Memos. One affordance, one level meter, one transcript. Nothing else competes for attention."
                phase = .done
            }
        case .transcribing:
            break
        }
    }
}

#Preview("Light") {
    ApertureMockup()
}

#Preview("Dark") {
    ApertureMockup()
        .preferredColorScheme(.dark)
}
