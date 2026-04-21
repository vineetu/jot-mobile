// Granola — “Editorial whitespace / calm”
//
// The whole app is a sentence. A massive serif headline telling you what
// the app is doing right now, a single pill that toggles recording, and a
// transcript that looks like a Notes document — not a chat bubble, not a
// card, just typography and margin. The quietest variant in the set.
//
// Prior art: Granola, iA Writer, Things 3, Linear changelog pages.

import SwiftUI

struct GranolaMockup: View {
    @State private var phase: Phase = .idle
    @State private var transcript: String = ""
    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    enum Phase { case idle, recording, transcribing, done }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 48) {
                    header
                    headline
                    recordPill
                    transcriptBlock
                    if phase == .done { footer }
                }
                .padding(.horizontal, 28)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {} label: { Image(systemName: "ellipsis") }
                        .accessibilityLabel("More")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Jot")
                        .font(.system(.headline, design: .serif))
                        .tracking(0.5)
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Elements

    private var header: some View {
        Text(metaLine)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(1.4)
    }

    private var headline: some View {
        Text(headlineText)
            .font(.system(size: 44, weight: .regular, design: .serif))
            .foregroundStyle(.primary)
            .lineSpacing(2)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordPill: some View {
        Button(action: toggle) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(phase == .recording ? Color.red : Color.accentColor)
                        .frame(width: 14, height: 14)
                        .scaleEffect(phase == .recording ? 1.2 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                   value: phase == .recording)
                }
                .frame(width: 20, height: 20)
                Text(pillLabel)
                    .font(.system(.body, design: .rounded).weight(.medium))
                Spacer(minLength: 0)
                Text(timeString)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(.thinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var transcriptBlock: some View {
        Group {
            if transcript.isEmpty {
                Text("The transcript will appear here as a paragraph — the way you'd read a letter, not a receipt.")
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.tertiary)
                    .lineSpacing(6)
            } else {
                Text(transcript)
                    .font(.system(.title3, design: .serif))
                    .foregroundStyle(.primary)
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 24) {
            Button("Copy") {}
                .buttonStyle(.plain)
                .font(.system(.body, design: .rounded).weight(.medium))
            Divider().frame(height: 16)
            Button("Share") {}
                .buttonStyle(.plain)
                .font(.system(.body, design: .rounded).weight(.medium))
            Divider().frame(height: 16)
            Button("Discard", role: .destructive) {}
                .buttonStyle(.plain)
                .font(.system(.body, design: .rounded).weight(.medium))
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private var metaLine: String {
        let today = Date().formatted(.dateTime.weekday(.wide).month().day())
        return "\(today) · On device"
    }

    private var headlineText: String {
        switch phase {
        case .idle: return "Ready to listen."
        case .recording: return "Listening…"
        case .transcribing: return "Writing it down…"
        case .done: return "Here you go."
        }
    }

    private var pillLabel: String {
        switch phase {
        case .idle, .done: return "Tap to dictate"
        case .recording: return "Tap to stop"
        case .transcribing: return "One moment"
        }
    }

    private var timeString: String {
        let s = Int(elapsed) % 60
        let m = Int(elapsed) / 60
        return String(format: "%02d:%02d", m, s)
    }

    private func toggle() {
        switch phase {
        case .idle, .done:
            phase = .recording
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                elapsed += 0.1
            }
        case .recording:
            timer?.invalidate()
            withAnimation(.smooth) { phase = .transcribing }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                withAnimation(.smooth) {
                    transcript = "The calmest version of Jot — nothing shouts, nothing competes. The headline tells you the state, the pill gives you the one verb, and the transcript reads like prose."
                    phase = .done
                }
            }
        case .transcribing:
            break
        }
    }
}

#Preview("Light") {
    GranolaMockup()
}

#Preview("Dark") {
    GranolaMockup()
        .preferredColorScheme(.dark)
}
