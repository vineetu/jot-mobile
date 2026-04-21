// Pulse — “Dynamic-Island-forward / voice-first”
//
// The interface disappears. A single floating “island” anchors the top of
// the screen — it expands when you record, sprouts a live waveform, and
// lays the transcript out BELOW it in a vertically-scrolling log.
// Dark OLED by default, glass materials where depth is needed. Pairs with
// voice-interaction-designer's “single active channel” pattern.
//
// Prior art: Apple Translate, Dynamic Island UX, Shazam, Arc's Little Arc.

import SwiftUI

struct PulseMockup: View {
    @State private var phase: Phase = .idle
    @State private var bars: [CGFloat] = Array(repeating: 0.2, count: 18)
    @State private var transcript: [TranscriptLine] = []
    @State private var timer: Timer?
    @State private var elapsed: TimeInterval = 0

    struct TranscriptLine: Identifiable {
        let id = UUID()
        let timestamp: String
        let text: String
    }

    enum Phase { case idle, recording, transcribing }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            scrollingLog
            island
                .padding(.top, 8)
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Island

    private var island: some View {
        HStack(spacing: 14) {
            Button(action: toggle) {
                ZStack {
                    Circle()
                        .fill(phase == .recording ? Color.red : Color.white.opacity(0.08))
                        .frame(width: 36, height: 36)
                    Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(phase == .recording ? "Stop" : "Start recording")

            if phase == .recording {
                waveform
                    .frame(height: 22)
                Text(timeString)
                    .font(.system(.footnote, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.9))
            } else if phase == .transcribing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)
                Text("Transcribing")
                    .font(.system(.footnote, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Text("Jot — tap to dictate")
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: phase == .idle ? 260 : 340)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)
        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: phase)
    }

    private var waveform: some View {
        HStack(spacing: 3) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(Color.white)
                    .frame(width: 3, height: max(4, 22 * h))
            }
        }
    }

    // MARK: - Log

    private var scrollingLog: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Spacer().frame(height: 72)
                if transcript.isEmpty {
                    emptyState
                } else {
                    ForEach(transcript) { line in
                        logRow(line)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No captures yet")
                .font(.system(.title3, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.95))
            Text("Tap the island above and start talking. Transcripts land here — newest first.")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.55))
                .lineSpacing(3)
        }
        .padding(.top, 40)
    }

    private func logRow(_ line: TranscriptLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(line.timestamp)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .tracking(1.2)
                .textCase(.uppercase)
            Text(line.text)
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(3)
                .textSelection(.enabled)
            HStack(spacing: 18) {
                rowAction("Copy", icon: "doc.on.doc")
                rowAction("Share", icon: "square.and.arrow.up")
                rowAction("Delete", icon: "trash", role: .destructive)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .offset(y: 12)))
    }

    private func rowAction(_ title: String, icon: String, role: ButtonRole? = nil) -> some View {
        Button(role: role) {} label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.medium))
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? .red : .white.opacity(0.7))
    }

    // MARK: - Helpers

    private var timeString: String {
        let s = Int(elapsed) % 60
        let m = Int(elapsed) / 60
        return String(format: "%d:%02d", m, s)
    }

    private func toggle() {
        switch phase {
        case .idle:
            withAnimation { phase = .recording }
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                elapsed += 0.08
                bars = bars.map { _ in CGFloat.random(in: 0.15...1.0) }
            }
        case .recording:
            timer?.invalidate()
            withAnimation { phase = .transcribing }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.spring) {
                    let stamp = Date().formatted(.dateTime.hour().minute())
                    transcript.insert(
                        TranscriptLine(
                            timestamp: stamp,
                            text: "Pulse direction — the island stays, the transcript stacks below it like a chat log. Newest captures at the top. Works especially well if we adopt voice commands."
                        ),
                        at: 0
                    )
                    phase = .idle
                }
            }
        case .transcribing:
            break
        }
    }
}

#Preview {
    PulseMockup()
}
