//
//  WizardChrome.swift
//  Jot
//
//  Phase 6 of the UX overhaul — Setup Wizard reskin.
//
//  Reusable chrome bits the 12 wizard panels share: the warm wallpaper
//  backdrop, progress dot rows (core 10 + optional 2), the top-right
//  glass close button, the coral primary CTA pill, secondary text
//  button, the bottom home-indicator bar, and the Fraunces title/body
//  typography pair that every panel uses.
//
//  Tokens are pulled from Phase 1 / Phase 4 (`JotDesign`, `Color`
//  extensions, `JotType`). Wallpaper + CTA gradient stops are
//  declared inline here because they live only inside the wizard
//  surface; the rest of the app never renders this backdrop.
//

import SwiftUI

// MARK: - Wallpaper

/// Warm radial/linear gradient backdrop used behind every wizard panel
/// (per the JSX `wallpaperLight` token). Lives inside the wizard surface
/// only — the rest of the app uses `JotDesign.background`.
struct WizardWallpaper: View {
    var body: some View {
        // `wallpaperLight` from the JSX: linear from `#fefcf9` at the
        // top through `#fef7f1` mid to `#fef0e8` at the bottom.
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.996, green: 0.988, blue: 0.976), location: 0.0),
                .init(color: Color(red: 0.996, green: 0.969, blue: 0.945), location: 0.60),
                .init(color: Color(red: 0.996, green: 0.941, blue: 0.910), location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Progress dots

private let wizardCoreStepCount = 10

/// 10-dot row representing the core Part A wizard progress (W1–W10).
/// Active dot is `jotAccent` 7pt; past dots are `jotMuteWeak` 5pt;
/// future dots are 5pt outlined.
struct WizardProgressDots: View {
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<wizardCoreStepCount, id: \.self) { i in
                dot(for: i)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(min(current + 1, wizardCoreStepCount)) of \(wizardCoreStepCount)")
    }

    @ViewBuilder
    private func dot(for index: Int) -> some View {
        let size: CGFloat = index == current ? 7 : 5
        if index == current {
            Circle()
                .fill(Color.jotAccent)
                .frame(width: size, height: size)
        } else if index < current {
            Circle()
                .fill(Color.jotMuteWeak)
                .frame(width: size, height: size)
        } else {
            Circle()
                .strokeBorder(Color.jotMuteWeak, lineWidth: 1.5)
                .frame(width: size, height: size)
        }
    }
}

/// 10 muted dots + dash separator + 2 active dots — the optional Part B
/// (W11–W12) indicator. Mirrors the JSX `WizDotsB` shape.
struct WizardProgressDotsOptional: View {
    let current: Int  // 0 or 1

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<wizardCoreStepCount, id: \.self) { _ in
                Circle()
                    .fill(Color.jotMuteWeak.opacity(0.5))
                    .frame(width: 4, height: 4)
            }
            Rectangle()
                .fill(Color.jotMuteWeak)
                .frame(width: 8, height: 1)
                .padding(.horizontal, 3)
            ForEach(0..<2, id: \.self) { i in
                optionalDot(for: i)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Optional step \(min(current + 1, 2)) of 2")
    }

    @ViewBuilder
    private func optionalDot(for index: Int) -> some View {
        let size: CGFloat = index == current ? 7 : 5
        if index == current {
            Circle()
                .fill(Color.jotAccent)
                .frame(width: size, height: size)
        } else if index < current {
            Circle()
                .fill(Color.jotMuteWeak)
                .frame(width: size, height: size)
        } else {
            Circle()
                .strokeBorder(Color.jotMuteWeak, lineWidth: 1.5)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Close button

/// 32pt top-right glass circle with an inset "X". On tap, confirms then
/// dismisses the wizard via `onClose`.
struct WizardCloseButton: View {
    let onClose: () -> Void

    @State private var showingConfirm = false

    var body: some View {
        Button {
            showingConfirm = true
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            // Apple HIG: ≥44pt hit target — extend the tap region without
            // moving the visual chrome.
            .padding(8)
        }
        .accessibilityLabel("Close setup")
        .confirmationDialog(
            "Skip setup?",
            isPresented: $showingConfirm,
            titleVisibility: .visible
        ) {
            Button("Skip setup", role: .destructive) {
                onClose()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can re-run setup any time from Settings.")
        }
    }
}

// MARK: - Primary CTA

/// Coral pill, full-width minus 20pt margins, ~52pt tall, white text 16pt
/// SemiBold. Coral-red gradient + inset highlight + drop shadow per the
/// JSX `WizPrimary`. Disabled state dims the gradient.
struct WizardPrimaryButton: View {
    let title: String
    var leadingSystemImage: String? = nil
    var subtitle: String? = nil
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if let leadingSystemImage {
                        Image(systemName: leadingSystemImage)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.32, blue: 0.28),
                            Color(red: 0.90, green: 0.23, blue: 0.19)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .inset(by: 0.5)
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                        .blendMode(.plusLighter)
                        .allowsHitTesting(false)
                )
                .shadow(
                    color: Color(red: 1.00, green: 0.23, blue: 0.19).opacity(0.35),
                    radius: 10,
                    x: 0,
                    y: 8
                )
                .opacity(isDisabled ? 0.55 : 1.0)
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .disabled(isDisabled)
            .accessibilityHint(subtitle ?? "")

            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(Color.jotMute)
            }
        }
    }
}

/// Glass-pill secondary button used by the W11 vocab "Done" CTA.
struct WizardGlassButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

/// 15pt SemiBold `.jotMute` text button used as the secondary action
/// beneath the primary CTA (e.g. "Maybe later", "Skip").
struct WizardSecondaryTextButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotMute)
                .frame(minHeight: 44)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Home indicator

/// 134×5pt dark pill at 4% opacity rendered at the bottom of every panel
/// — purely visual chrome that echoes the system home indicator.
struct WizardHomeIndicator: View {
    var body: some View {
        Capsule()
            .fill(Color.jotInk.opacity(0.04))
            .frame(width: 134, height: 5)
            .padding(.bottom, 8)
            .accessibilityHidden(true)
    }
}

// MARK: - Typography helpers

/// Editorial title used at the top of most panels — Fraunces SemiBold
/// at a tunable size (defaults to 32pt, W1 overrides to 80pt, W6/W7/W8/W11
/// override to 26-28pt).
struct WizardTitle: View {
    let text: String
    var size: CGFloat = 32

    var body: some View {
        Text(text)
            .font(.custom(JotType.frauncesSemiBold, size: size))
            .foregroundStyle(Color.jotInk)
            .tracking(-0.5)
            .multilineTextAlignment(.center)
            .lineSpacing(1.1)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 15pt regular grey-ish body used beneath the title.
struct WizardBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
            .multilineTextAlignment(.center)
            .lineSpacing(1.5)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Italic Fraunces sub-note used for the "We'll detect when you're back"
/// / "iOS will show a warning" copy that several panels share. The 9pt
/// opsz italic cut is the text-tuned face that reads correctly at 13pt.
struct WizardItalicNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.custom(JotType.frauncesItalicText, size: 13))
            .foregroundStyle(Color.jotMute)
            .multilineTextAlignment(.center)
            .lineSpacing(1.4)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Panel scaffold

/// Shared scaffold that lays out the wallpaper + top progress/close row
/// + scrollable middle body + bottom-pinned CTA group. Every step view
/// renders into the `content` slot for its body and the `footer` slot
/// for its CTAs.
struct WizardPanel<Content: View, Footer: View>: View {
    let header: WizardHeader
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        ZStack {
            WizardWallpaper()

            VStack(spacing: 0) {
                HStack {
                    header.dots
                    Spacer()
                    WizardCloseButton(onClose: header.onClose)
                        // The 8pt padding on the close button widens the hit
                        // region — compensate so the visual stays flush to
                        // the right edge.
                        .padding(.trailing, -8)
                }
                .frame(height: 36)
                .padding(.horizontal, 20)
                .padding(.top, 16)

                ScrollView {
                    content()
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                        .padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)

                VStack(spacing: 10) {
                    footer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 22)

                WizardHomeIndicator()
            }
        }
    }
}

/// Header descriptor: which dots row to render plus the close action.
struct WizardHeader {
    enum DotsStyle {
        case core(current: Int)
        case optional(current: Int)
    }

    let style: DotsStyle
    let onClose: () -> Void

    @ViewBuilder
    var dots: some View {
        switch style {
        case .core(let current):
            WizardProgressDots(current: current)
        case .optional(let current):
            WizardProgressDotsOptional(current: current)
        }
    }
}
