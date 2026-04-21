// Dictaphone — “Editorial luxury / warm retro”
//
// The warmest variant. New York serif for headlines and body, a warm
// paper-cream background (one justified brand color), tactile REC pill,
// and a thin scribble-line amplitude graph instead of bars. Feels like
// a pocket recorder an essayist would keep in their jacket.
//
// This is the strongest “branded” direction that still feels Apple-
// adjacent — there's precedent in Journal, Books, and Apple TV+ web pages.

import SwiftUI

struct DictaphoneMockup: View {
    @State private var phase: Phase = .idle
    @State private var points: [CGFloat] = Array(repeating: 0.5, count: 80)
    @State private var elapsed: TimeInterval = 0
    @State private var transcript: String = ""
    @State private var timer: Timer?

    enum Phase { case idle, recording, transcribing, done }

    // One justified brand color — a warm cream paper tone.
    // Light-mode only; dark mode falls back to system background.
    private let cream = Color(red: 0.98, green: 0.95, blue: 0.89)
    private let ink = Color(red: 0.13, green: 0.10, blue: 0.08)

    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 28) {
                masthead
                headline
                scribble
                recPill
                Spacer(minLength: 8)
                transcriptBlock
                if phase == .done { footer }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .preferredColorScheme(.light)
        .tint(Color(red: 0.62, green: 0.13, blue: 0.13))
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    // MARK: - Surfaces

    private var paper: Color { cream }

    // MARK: - Elements

    private var masthead: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Jot")
                    .font(.system(size: 40, weight: .black, design: .serif))
                    .foregroundStyle(ink)
                Text("·")
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .foregroundStyle(ink.opacity(0.4))
                Text("dictate, quietly")
                    .font(.system(size: 16, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(ink.opacity(0.55))
                Spacer()
            }
            Rectangle()
                .fill(ink.opacity(0.15))
                .frame(height: 1)
                .padding(.top, 8)
        }
    }

    private var headline: some View {
        Text(headlineText)
            .font(.system(size: 30, weight: .regular, design: .serif))
            .foregroundStyle(ink)
            .lineSpacing(2)
    }

    private var scribble: some View {
        GeometryReader { geo in
            Path { path in
                guard !points.isEmpty else { return }
                let step = geo.size.width / CGFloat(points.count - 1)
                let midY = geo.size.height / 2
                path.move(to: CGPoint(x: 0, y: midY))
                for (i, v) in points.enumerated() {
                    let x = CGFloat(i) * step
                    let y = midY + (v - 0.5) * geo.size.height
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(
                phase == .recording
                    ? Color(red: 0.62, green: 0.13, blue: 0.13)
                    : ink.opacity(0.35),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
        }
        .frame(height: 44)
        .animation(.easeOut(duration: 0.12), value: points)
    }

    private var recPill: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(phase == .recording ? ink : Color(red: 0.62, green: 0.13, blue: 0.13))
                        .frame(width: 14, height: 14)
                }
                Text(buttonLabel)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .tracking(0.5)
                Spacer(minLength: 0)
                Text(timeString)
                    .font(.system(.callout, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(ink.opacity(0.55))
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(ink.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: ink.opacity(0.10), radius: 14, y: 6)
        }
        .buttonStyle(.plain)
    }

    private var transcriptBlock: some View {
        Group {
            if transcript.isEmpty {
                Text("— Your transcription will set here, like prose from a notebook.")
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .italic()
                    .foregroundStyle(ink.opacity(0.4))
                    .lineSpacing(4)
            } else {
                Text(transcript)
                    .font(.system(size: 19, weight: .regular, design: .serif))
                    .foregroundStyle(ink)
                    .lineSpacing(6)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 22) {
            footerButton("Copy")
            footerButton("Share")
            footerButton("New entry", destructive: false)
            Spacer()
        }
        .padding(.top, 8)
    }

    private func footerButton(_ title: String, destructive: Bool = false) -> some View {
        Button {} label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .serif))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(destructive ? .red : ink.opacity(0.7))
                .padding(.bottom, 2)
                .overlay(alignment: .bottom) {
                    Rectangle().frame(height: 0.5).foregroundStyle(ink.opacity(0.3))
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private var headlineText: String {
        switch phase {
        case .idle: return "A place to speak, and be written down."
        case .recording: return "Listening, carefully."
        case .transcribing: return "Setting the type…"
        case .done: return "Fresh ink."
        }
    }

    private var buttonLabel: String {
        switch phase {
        case .idle, .done: return "Begin dictation"
        case .recording: return "End recording"
        case .transcribing: return "Please wait"
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
            timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                elapsed += 0.08
                points.removeFirst()
                points.append(CGFloat.random(in: 0.15...0.85))
            }
        case .recording:
            timer?.invalidate()
            phase = .transcribing
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                transcript = "Dictaphone — serif-warm, paper-tone, a scribble instead of a bar graph. A pocket recorder built for someone who writes essays. Opinionated and branded, but adjacent enough to Apple's visual language not to feel foreign."
                phase = .done
            }
        case .transcribing:
            break
        }
    }
}

#Preview {
    DictaphoneMockup()
}
