// Ledger — “NothingJot × Pulse hybrid”
//
// NothingJot's instrument DNA (mono timer, VU, “operating a device”) on
// Pulse's bones (Dynamic-Island-forward pill, chronological log, dark).
//
// Explicit departures from Nothing's IP (see IP audit in the design doc):
// • No dot-matrix background → horizontal ledger rules.
// • Not red → amber accent (warm CRT phosphor).
// • Not Ndot / Space Mono → SF Mono via .design: .monospaced.
// • No parenthetical product nomenclature, no “JOT · 01” header strip —
//   the pill is the only chrome.

import SwiftUI

struct LedgerMockup: View {
    @State private var phase: Phase = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var bars: [CGFloat] = Array(repeating: 0.3, count: 12)
    @State private var entries: [Entry] = [
        Entry(id: UUID(), index: 41, time: "9:02 AM",
              body: "Ship the release notes. Don't forget the migration bullet — the one about the app-group container. That's the only thing that breaks people."),
        Entry(id: UUID(), index: 40, time: "8:47 AM",
              body: "Remind me to pick up oat milk on the way home.")
    ]
    @State private var timer: Timer?

    struct Entry: Identifiable {
        let id: UUID
        let index: Int
        let time: String
        let body: String
    }

    enum Phase { case idle, recording, transcribing }

    private let amber = Color(red: 1.0, green: 0.72, blue: 0.10)
    private let ink  = Color(red: 0.06, green: 0.06, blue: 0.07)

    var body: some View {
        ZStack(alignment: .top) {
            ink.ignoresSafeArea()
            ledgerRules.ignoresSafeArea()
            log
            pill.padding(.top, 10).padding(.horizontal, 14)
        }
        .preferredColorScheme(.dark)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Background (ledger rules)

    private var ledgerRules: some View {
        Canvas { ctx, size in
            let step: CGFloat = 32
            var y: CGFloat = step
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 0.5)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.035)))
                y += step
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Pill (the instrument)

    private var pill: some View {
        HStack(spacing: 12) {
            recDot

            timerLabel

            vuStrip
                .frame(height: 20)
                .layoutPriority(1)

            statusChip
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: phase)
    }

    private var recDot: some View {
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(phase == .recording ? amber : Color.white.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: phase == .recording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(phase == .recording ? ink : .white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(phase == .recording ? "Stop recording" : "Start recording")
    }

    private var timerLabel: some View {
        Text(timeString)
            .font(.system(.footnote, design: .monospaced).weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.92))
            .contentTransition(.numericText())
    }

    private var vuStrip: some View {
        HStack(spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, h in
                Capsule()
                    .fill(phase == .recording ? amber : Color.white.opacity(0.22))
                    .frame(width: 2, height: max(3, 20 * h))
            }
        }
    }

    private var statusChip: some View {
        Text(statusText)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .tracking(2)
            .foregroundStyle(phase == .recording ? amber : .white.opacity(0.6))
            .frame(minWidth: 52, alignment: .trailing)
    }

    // MARK: - Log (chronological entries)

    private var log: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 76)
                if entries.isEmpty { emptyState }
                ForEach(entries) { entry in
                    entryRow(entry)
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                        .frame(height: 0.5)
                }
                Spacer().frame(height: 40)
            }
            .padding(.horizontal, 20)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("— no entries —")
                .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                .tracking(2).foregroundStyle(.white.opacity(0.55))
            Text("Tap the mic to start your ledger.")
                .font(.callout).foregroundStyle(.white.opacity(0.45))
        }
        .padding(.vertical, 32).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func entryRow(_ entry: Entry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(String(format: "#%04d", entry.index))
                    .foregroundStyle(amber)
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text(entry.time).foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
            .font(.system(.footnote, design: .monospaced).weight(.bold))
            Text(entry.body)
                .font(.body)
                .foregroundStyle(.white.opacity(0.92))
                .lineSpacing(3)
                .textSelection(.enabled)
            HStack(spacing: 18) {
                action("COPY"); action("SHARE"); action("DELETE", destructive: true)
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func action(_ title: String, destructive: Bool = false) -> some View {
        Button(role: destructive ? .destructive : nil) {} label: {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .monospaced))
                .tracking(2)
                .foregroundStyle(destructive ? .red : .white.opacity(0.6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var timeString: String {
        let s = Int(elapsed) % 60
        let m = Int(elapsed) / 60
        return String(format: "%02d:%02d", m, s)
    }

    private var statusText: String {
        switch phase {
        case .idle: return "READY"
        case .recording: return "REC"
        case .transcribing: return "PROC"
        }
    }

    private func toggle() {
        switch phase {
        case .idle:
            withAnimation { phase = .recording }
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                elapsed += 0.08
                bars = bars.map { _ in CGFloat.random(in: 0.18...1.0) }
            }
        case .recording:
            timer?.invalidate()
            withAnimation { phase = .transcribing }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                withAnimation(.spring) {
                    let nextIndex = (entries.first?.index ?? 41) + 1
                    entries.insert(
                        Entry(id: UUID(), index: nextIndex,
                              time: Date().formatted(.dateTime.hour().minute()),
                              body: "Ledger direction — instrument pill at the top, amber accents instead of red, ruled paper instead of dot-matrix. The transcript log is the page; each entry gets a number."),
                        at: 0
                    )
                    phase = .idle
                    bars = Array(repeating: 0.3, count: 12)
                }
            }
        case .transcribing:
            break
        }
    }
}

#Preview {
    LedgerMockup()
}
