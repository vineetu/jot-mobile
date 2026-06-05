//
//  HowItWorksStep.swift
//  Jot
//
//  Phase 6 — wizard panel W4 (renumbered from W5 after the bundled-Parakeet
//  ship retired the standalone speech-model download step).
//
//  Step-by-step redesign (wizard-overhaul): the capture flow is taught as
//  FOUR explicit numbered steps, each held for ~5 seconds in a looping
//  20-second mini-phone animation, with the active step's number shown in the
//  scene AND highlighted in the list below:
//    1. Tap Dictate on your keyboard
//    2. Jot opens and starts recording
//    3. Swipe back to your app
//    4. Stop from the keyboard when you're done
//  The honest "we'd skip this if we could" note sits at the bottom, just above
//  the Got it button. Reduce-motion renders a single static frame (no loop).
//

import SwiftUI

struct HowItWorksStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Wall-clock anchor for the loop, reset on appear.
    @State private var startDate = Date()

    /// 4 steps × ~3.25s each, looping (sped up ~1.5× from the original 20s).
    private let loopDuration: Double = 13

    private let steps: [(n: Int, text: String)] = [
        (1, "Tap Jot down on your keyboard"),
        (2, "Jot opens and starts recording"),
        (3, "Swipe back to your app"),
        (4, "Stop from the keyboard when you're done"),
    ]

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 3), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 8)

                WizardItalicTitle(text: "How it works", size: 35)

                animatedContent

                Spacer(minLength: 8)
            }
        } footer: {
            VStack(spacing: 12) {
                // The honest note sits at the bottom, just above Got it.
                Text("We'd skip this step if we could. Apple doesn't let keyboards use the mic directly — so Jot hops back to capture. If that ever changes, this goes away.")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(Color.jotMute)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 320)

                WizardPrimaryButton(title: "Got it", action: onAdvance)
                    .padding(.horizontal, 16)
            }
        }
        .onAppear { startDate = Date() }
    }

    /// Reduce-motion → one static frame (no active step highlight). Otherwise a
    /// `TimelineView(.animation)` drives a real per-frame `phase` so each step
    /// holds for its full 5s and the scene + list stay in lockstep.
    @ViewBuilder
    private var animatedContent: some View {
        if reduceMotion {
            // Reduce-motion: a single static frame on step 1 (so the first step
            // reads as the entry point rather than a fully-greyed list).
            content(phase: 0.12, step: 1)
        } else {
            TimelineView(.animation) { context in
                let elapsed = context.date.timeIntervalSince(startDate)
                let p = CGFloat(elapsed.truncatingRemainder(dividingBy: loopDuration) / loopDuration)
                content(phase: p, step: currentStep(p))
            }
        }
    }

    private func content(phase: CGFloat, step: Int) -> some View {
        VStack(spacing: 20) {
            HowScene(phase: phase, step: step)
            stepList(activeStep: step)
        }
    }

    /// 1…4 for the four 5-second segments of the 20s loop.
    private func currentStep(_ phase: CGFloat) -> Int {
        min(4, Int(phase * 4) + 1)
    }

    // MARK: - Step list (active row highlights in sync with the scene)

    private func stepList(activeStep: Int) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(steps, id: \.n) { item in
                stepRow(item.n, item.text, active: item.n == activeStep)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func stepRow(_ n: Int, _ text: String, active: Bool) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(active ? Color.jotAccent : Color.jotAccent.opacity(0.14))
                    .frame(width: 26, height: 26)
                Text("\(n)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(active ? Color.white : Color.jotAccent)
            }

            Text(text)
                .font(.system(size: 15, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.jotInk : Color.jotPageInkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .opacity(active ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.25), value: active)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(n): \(text)")
    }
}

// MARK: - HowScene (animated mini-phone, 168×248, 20s looping, 4 step cues)

/// Mini-phone illustration teaching the four-step capture loop. `phase` (0→1
/// over 20s) and `step` (1…4, or 0 in the reduce-motion static frame) come from
/// the parent's `TimelineView` so the scene and the step list never drift.
/// Each step has ONE clear cue:
///   1 tap-ring pulses on the Dictate pill · 2 record dot pulses + pill→Stop ·
///   3 swipe arrow sweeps the bottom edge · 4 dictated bubble fades in.
private struct HowScene: View {
    let phase: CGFloat
    let step: Int

    @Environment(\.colorScheme) private var colorScheme

    private let frameW: CGFloat = 168
    private let frameH: CGFloat = 248
    private let kbHeight: CGFloat = 118

    /// Progress within the current 5s step, 0→1.
    private var segT: CGFloat { (phase * 4).truncatingRemainder(dividingBy: 1) }

    /// Recording is live during steps 2 and 3.
    private var recording: Bool { step == 2 || step == 3 }

    /// Fast 0…1 pulse for the record dot / tap ring. Multiplier scaled with the
    /// loop (40 × 13/20 ≈ 26) so its real-time pulse rate stays ~constant.
    private var pulse: CGFloat { 0.5 + 0.5 * sin(phase * .pi * 2 * 26) }

    // MARK: Phone chrome colors (scene-internal — inline hexes are fine here)

    private var phoneBg: Color {
        colorScheme == .dark
            ? Color(red: 0x0C / 255, green: 0x14 / 255, blue: 0x22 / 255)
            : Color(red: 0xEA / 255, green: 0xEF / 255, blue: 0xF7 / 255)
    }
    private var islandBg: Color { Color(red: 0x05 / 255, green: 0x08 / 255, blue: 0x0D / 255) }
    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color(red: 20/255, green: 30/255, blue: 50/255).opacity(0.10)
    }
    private var bubbleNeutral: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color(red: 40/255, green: 60/255, blue: 96/255).opacity(0.10)
    }
    private var bubbleSoft: Color { Color.jotAccent.opacity(0.20) }
    private var kbFill: Color {
        colorScheme == .dark
            ? Color(red: 0x18 / 255, green: 0x1F / 255, blue: 0x2C / 255)
            : Color(red: 0xD2 / 255, green: 0xD6 / 255, blue: 0xDE / 255)
    }
    private var kbKey: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.white
    }
    private var kbTopBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
    private var placeholderInk: Color {
        colorScheme == .dark ? Color.white.opacity(0.5) : Color(red: 40/255, green: 52/255, blue: 74/255).opacity(0.45)
    }
    private var homeBar: Color {
        colorScheme == .dark ? Color.white.opacity(0.55) : Color(red: 20/255, green: 30/255, blue: 50/255).opacity(0.4)
    }
    /// Blue gradient (ACCENTS.blue.grad): #2E9BFF → #0E7AE6 → #0064CC.
    private var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0x2E / 255, green: 0x9B / 255, blue: 0xFF / 255),
                Color(red: 0x0E / 255, green: 0x7A / 255, blue: 0xE6 / 255),
                Color(red: 0x00 / 255, green: 0x64 / 255, blue: 0xCC / 255),
            ],
            startPoint: .top, endPoint: .bottom
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Same phone wallpaper for all four steps — consistent feel; only the
            // CONTENT inside changes (keyboard ⇄ empty Jot panel), never the whole
            // screen, so step 2–3 never read as a pasted-in screenshot.
            phoneBg

            if step == 2 || step == 3 {
                // Steps 2–3: the Jot recording screen — a FULL-PAGE empty dark
                // panel (just the shell, no live text, no controls) + the record
                // dot; step 3 adds the swipe-back coaching sweeping the bottom.
                heroPanel
                swipeArrow
            } else {
                // Steps 1 & 4 (and the reduce-motion neutral frame): your app +
                // the Jot keyboard. Step 1 taps Dictate; step 4 taps Stop.
                messageThread
                keyboard
            }

            dynamicIsland
            homeIndicator
            stepBadge
        }
        .frame(width: frameW, height: frameH)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.5), radius: 24, x: 0, y: 18)
        .accessibilityElement()
        .accessibilityLabel("Animation showing four steps: tap Jot down, Jot records, swipe back to your app, stop from the keyboard")
    }

    /// Steps 2–3: the Jot recording panel — a clearly-bounded light card filling
    /// the mini-phone, with a faint, bottom-anchored "live transcript"
    /// placeholder (a few rounded-rect lines of decreasing width) so it reads as
    /// Jot's recording screen rather than a blank page. Kept abstract — it's a
    /// mockup. Insets leave room for the dynamic island on top and the
    /// home-indicator at the bottom.
    private var heroPanel: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .overlay(alignment: .bottomLeading) {
                // Faint streaming-transcript placeholder, parked above the swipe
                // coaching so the two never overlap.
                VStack(alignment: .leading, spacing: 7) {
                    transcriptLine(widthFraction: 0.74)
                    transcriptLine(widthFraction: 0.60)
                    transcriptLine(widthFraction: 0.42)
                }
                .padding(.leading, 22)
                .padding(.bottom, 52)
            }
            .padding(.horizontal, 12)
            .padding(.top, 34)
            .padding(.bottom, 16)
            .frame(width: frameW, height: frameH)
    }

    /// One faint streaming-transcript placeholder line.
    private func transcriptLine(widthFraction: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(placeholderInk.opacity(0.5))
            .frame(width: (frameW - 24) * widthFraction, height: 8)
    }

    // MARK: Layers

    /// Centered step badge sitting just below the dynamic island — the current
    /// step number (hidden in the reduce-motion neutral frame, step 0).
    @ViewBuilder
    private var stepBadge: some View {
        if step >= 1 {
            HStack(spacing: 5) {
                Text("STEP")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(0.6)
                    .foregroundStyle(Color.white.opacity(0.9))
                Text("\(step)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(Color.white)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.jotAccent, in: Capsule(style: .continuous))
            .frame(width: frameW, height: frameH, alignment: .top)
            .padding(.top, 30)
            .accessibilityHidden(true)
        }
    }

    /// z-order — dynamic island with the pulsing record dot (steps 2–3).
    private var dynamicIsland: some View {
        HStack {
            Spacer(minLength: 0)
            Circle()
                .fill(Color.jotAccent)
                .frame(width: 7, height: 7)
                .opacity(recording ? (0.4 + 0.6 * pulse) : 0)
                .padding(.trailing, 7)
        }
        .frame(width: 58, height: 17)
        .background(islandBg)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.top, 9)
    }

    /// The user's app (a message thread). The dictated bubble fades in on step 4.
    private var messageThread: some View {
        VStack(alignment: .leading, spacing: 8) {
            bubble(widthFraction: 0.62, height: 16, fill: bubbleNeutral, trailing: false)
            bubble(widthFraction: 0.54, height: 16, fill: bubbleSoft, trailing: true)
            bubble(widthFraction: 0.46, height: 16, fill: bubbleNeutral, trailing: false)
            // The dictated text appearing — step 4 only.
            HStack {
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accentGradient)
                    .frame(width: (frameW - 24) * 0.72, height: 30)
                    .opacity(dictatedOpacity)
                    .scaleEffect(dictatedScale, anchor: .bottomTrailing)
                    .offset(y: dictatedOffsetY)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 34)
        .frame(width: frameW, height: frameH, alignment: .top)
    }

    /// Step 4: bubble slides up + fades in over the first ~1.5s of the step.
    private var dictatedOpacity: CGFloat { step == 4 ? min(1, segT * 3.5) : 0 }
    private var dictatedScale: CGFloat { step == 4 ? min(1, 0.96 + segT * 0.14) : 0.96 }
    private var dictatedOffsetY: CGFloat { step == 4 ? max(0, 6 - segT * 21) : 6 }

    private func bubble(widthFraction: CGFloat, height: CGFloat, fill: Color, trailing: Bool) -> some View {
        HStack(spacing: 0) {
            if trailing { Spacer(minLength: 0) }
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(fill)
                .frame(width: (frameW - 24) * widthFraction, height: height)
            if !trailing { Spacer(minLength: 0) }
        }
    }

    /// The Jot keyboard — stays up the whole time ("your keyboard"). The
    /// Dictate pill becomes a Stop square while recording, and shows a pulsing
    /// tap-ring on step 1.
    private var keyboard: some View {
        VStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(placeholderInk.opacity(0.4))
                .frame(width: (frameW - 24) * 0.70, height: 11)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(kbKey)
                    .frame(width: 30, height: 30)

                // Dictate ⇄ Stop pill.
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(accentGradient)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity)
                    .overlay(pillIndicator)
                    .overlay(pillRing)

                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(kbKey)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: frameW, height: kbHeight)
        .background(kbFill)
        .overlay(Rectangle().fill(kbTopBorder).frame(height: 1), alignment: .top)
        .frame(width: frameW, height: frameH, alignment: .bottom)
    }

    /// Dot when idle (Dictate), white square when recording (Stop).
    @ViewBuilder
    private var pillIndicator: some View {
        if step == 4 {
            // Stop = white square.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .frame(width: 9, height: 9)
        } else {
            Circle().fill(Color.white).frame(width: 9, height: 9)
        }
    }

    /// Step 1: an outward tap-ring pulses on the Dictate pill ("tap Dictate").
    /// Step 4: a ring pulses around the Stop square ("tap Stop").
    @ViewBuilder
    private var pillRing: some View {
        if step == 1 {
            let t = (segT * 2).truncatingRemainder(dividingBy: 1)
            Circle()
                .stroke(Color.white, lineWidth: 2)
                .frame(width: 26, height: 26)
                .scaleEffect(0.7 + t * 0.9)
                .opacity(Double(0.7 * (1 - t)))
        } else if step == 4 {
            let t = (segT * 1.8).truncatingRemainder(dividingBy: 1)
            Circle()
                .stroke(Color.white.opacity(0.95), lineWidth: 2)
                .frame(width: 22, height: 22)
                .scaleEffect(0.85 + t * 0.65)
                .opacity(Double(0.85 * (1 - t)))
        }
    }

    /// Step 3: the swipe-back arrow sweeps along the bottom edge (≈2 sweeps).
    @ViewBuilder
    private var swipeArrow: some View {
        if step == 3 {
            let t = (segT * 2).truncatingRemainder(dividingBy: 1)
            HStack(spacing: 6) {
                SwipeArrowShape()
                    .stroke(Color.jotAccent, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .frame(width: 36, height: 18)
                Text("SWIPE")
                    .font(.system(size: 9.5, weight: .heavy))
                    .tracking(1.0)
                    .foregroundStyle(Color.jotAccent)
            }
            // Centered horizontally, parked comfortably INSIDE the hero card
            // (above its 16pt bottom inset) and below the transcript lines;
            // sweeps a short distance right→left, staying fully inside the frame
            // (no clipping at the edge).
            .frame(width: frameW, height: frameH, alignment: .bottom)
            .padding(.bottom, 26)
            .offset(x: 26 - 52 * t)
            .opacity(Double(sin(t * .pi)))
        }
    }

    /// Home indicator bar.
    private var homeIndicator: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(homeBar)
            .frame(width: 64, height: 4)
            .frame(width: frameW, height: frameH, alignment: .bottom)
            .padding(.bottom, 7)
    }
}

/// The swipe-back chevron-arrow from the prototype SVG
/// (`M38 10H6 M14 3L5 10l9 7`) in a 40×20 box.
private struct SwipeArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 40
        let sy = rect.height / 20
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * sx, y: y * sy) }
        var p = Path()
        p.move(to: pt(38, 10))
        p.addLine(to: pt(6, 10))
        p.move(to: pt(14, 3))
        p.addLine(to: pt(5, 10))
        p.addLine(to: pt(14, 17))
        return p
    }
}
