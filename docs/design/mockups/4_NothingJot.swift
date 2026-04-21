// NothingJot — “Monochrome industrial / Swiss”
//
// The opinionated flavor: black or white, typographic, mechanical.
// Segmented VU meter like a tape deck. SF Mono for everything numeric.
// Dot-matrix feel via a subtle grid in the background. Not the HIG-
// safest direction — but the most distinctive. If we ever do a "Pro"
// mode or a branded micro-subtheme, it lives here.
//
// Prior art: Nothing OS, Teenage Engineering, early Teenager Engineering
// OP-1, Braun Dieter Rams calculators.

import SwiftUI

struct NothingJotMockup: View {
    @State private var phase: Phase = .idle
    @State private var elapsed: TimeInterval = 0
    @State private var level: Int = 4   // 0...24 segments
    @State private var transcript: String = ""
    @State private var timer: Timer?

    enum Phase { case idle, recording, transcribing, done }

    var body: some View {
        ZStack {
            background
            VStack(spacing: 0) {
                topStrip
                Spacer(minLength: 0)
                bigTimer
                Spacer().frame(height: 32)
                vuMeter
                Spacer().frame(height: 32)
                recButton
                Spacer(minLength: 0)
                transcriptPane
                Spacer().frame(height: 12)
                bottomStrip
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .foregroundStyle(.primary)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Background

    private var background: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            // Dot-matrix at 3% opacity — evokes industrial.
            Canvas { ctx, size in
                let step: CGFloat = 14
                let dot = CGSize(width: 1.2, height: 1.2)
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        ctx.fill(
                            Path(ellipseIn: CGRect(origin: CGPoint(x: x, y: y), size: dot)),
                            with: .color(.primary.opacity(0.08))
                        )
                        x += step
                    }
                    y += step
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
    }

    // MARK: - Strips

    private var topStrip: some View {
        HStack {
            Text("JOT · 01")
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(3)
            Spacer()
            Text(statusLabel)
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(3)
                .foregroundStyle(phase == .recording ? Color.red : .primary)
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) {
            Rectangle().frame(height: 1).foregroundStyle(.primary)
        }
    }

    private var bottomStrip: some View {
        HStack {
            Text("ON-DEVICE · PARAKEET")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(2.4)
                .foregroundStyle(.secondary)
            Spacer()
            Text("v1.0")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(2.4)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            Rectangle().frame(height: 1).foregroundStyle(.primary.opacity(0.4))
        }
    }

    // MARK: - Core

    private var bigTimer: some View {
        Text(timeString)
            .font(.system(size: 84, weight: .heavy, design: .monospaced))
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    private var vuMeter: some View {
        HStack(spacing: 3) {
            ForEach(0..<24, id: \.self) { i in
                Rectangle()
                    .fill(color(for: i))
                    .frame(width: 10, height: 28)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func color(for i: Int) -> Color {
        if i >= level { return .primary.opacity(0.1) }
        if i >= 20 { return .red }
        if i >= 16 { return .orange }
        return .primary
    }

    private var recButton: some View {
        Button(action: toggle) {
            HStack(spacing: 16) {
                Circle()
                    .fill(phase == .recording ? Color.red : Color.primary)
                    .frame(width: 20, height: 20)
                Text(phase == .recording ? "STOP" : "REC")
                    .font(.system(size: 22, weight: .black, design: .monospaced))
                    .tracking(4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }

    private var transcriptPane: some View {
        ScrollView {
            Text(transcript.isEmpty ? "> awaiting input" : transcript)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(transcript.isEmpty ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(14)
        }
        .frame(minHeight: 140, maxHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.6), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var timeString: String {
        let s = Int(elapsed) % 60
        let m = Int(elapsed) / 60
        return String(format: "%02d:%02d", m, s)
    }

    private var statusLabel: String {
        switch phase {
        case .idle: return "STANDBY"
        case .recording: return "● REC"
        case .transcribing: return "PROC"
        case .done: return "DONE"
        }
    }

    private func toggle() {
        switch phase {
        case .idle, .done:
            phase = .recording
            elapsed = 0
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                elapsed += 0.1
                level = Int.random(in: 4...22)
            }
        case .recording:
            timer?.invalidate()
            level = 0
            phase = .transcribing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                transcript = "> nothing-jot flavour. monochrome. typographic. mechanical. the vu meter is the personality; everything else gets out of the way."
                phase = .done
            }
        case .transcribing:
            break
        }
    }
}

#Preview("Light") {
    NothingJotMockup()
}

#Preview("Dark") {
    NothingJotMockup()
        .preferredColorScheme(.dark)
}
