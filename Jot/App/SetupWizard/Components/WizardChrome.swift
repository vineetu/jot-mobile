//
//  WizardChrome.swift
//  Jot
//
//  Phase 6 of the UX overhaul — Setup Wizard reskin.
//
//  Reusable chrome bits the 10 wizard panels share: the standard v0.9
//  wallpaper backdrop, progress dot rows (core 8 + optional 2), the top-right
//  glass close button, the coral primary CTA pill, secondary text
//  button, the bottom home-indicator bar, and the wizard title/body
//  typography helpers that every panel uses.
//
//  Tokens are pulled from Phase 1 / Phase 4 (`JotDesign`, `Color`
//  extensions, `JotType`). The wallpaper is the app-wide v0.9
//  `WallpaperBackground`; CTA gradient stops use the shared coral tokens.
//

import SwiftUI

// MARK: - Wallpaper

/// Standard v0.9 app wallpaper used behind every wizard panel.
struct WizardWallpaper: View {
    var body: some View {
        WallpaperBackground()
    }
}

// MARK: - Progress dots

private let wizardCoreStepCount = 7

/// 7-dot row representing the core Part A wizard progress (W1–W7).
/// The W3 "Download speech model" panel was removed when the default
/// Parakeet bundle moved into the IPA, and the W5 in-app try-it step
/// was later dropped — total core count is 7.
/// Active dot is `jotAccent` 7pt; inactive dots use `jotPageInk.opacity(0.22)`.
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
                .fill(Color.jotPageInk.opacity(0.22))
                .frame(width: size, height: size)
        } else {
            Circle()
                .strokeBorder(Color.jotPageInk.opacity(0.22), lineWidth: 1.5)
                .frame(width: size, height: size)
        }
    }
}

/// 7 muted dots + dash separator + 2 active dots — the Optional Step 1/2
/// indicator. Mirrors the JSX `WizDotsB` shape (7 muted dots after the
/// W3 speech-model step and W5 in-app try-it step were both removed).
struct WizardProgressDotsOptional: View {
    let current: Int  // 0 or 1

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<wizardCoreStepCount, id: \.self) { _ in
                Circle()
                    .fill(Color.jotPageInk.opacity(0.22))
                    .frame(width: 5, height: 5)
            }
            Rectangle()
                .fill(Color.jotPageInk.opacity(0.22))
                .frame(width: 12, height: 1.5)
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
                .fill(Color.jotPageInk.opacity(0.22))
                .frame(width: size, height: size)
        } else {
            Circle()
                .strokeBorder(Color.jotPageInk.opacity(0.22), lineWidth: 1.5)
                .frame(width: size, height: size)
        }
    }
}

// MARK: - Back button

/// 32pt top-left glass circle with a leading chevron. On tap, calls
/// `onBack` to pop one step on the wizard's step machine. Only shown
/// when the current step actually has a previous step (Welcome has no
/// back affordance). Mirrors the close button's hit-target padding
/// (+8pt) so the 44pt Apple HIG minimum is honored without moving the
/// visual chrome.
struct WizardBackButton: View {
    let onBack: () -> Void

    var body: some View {
        Button(action: onBack) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                Circle()
                    .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
                Image(systemName: "chevron.backward")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
            .padding(8)
        }
        .accessibilityLabel("Back")
        .accessibilityHint("Return to the previous step.")
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
                            Color.jotCoralTop,
                            Color.jotCoralBottom
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Capsule(style: .continuous)
                )
                .overlay(
                    Capsule(style: .continuous)
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
                .contentShape(Capsule(style: .continuous))
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

/// Glass-pill secondary button used by the Optional Step 1 vocab "Done" CTA.
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
/// at a tunable size (defaults to 32pt, W1 overrides to 80pt, W5/W6/W7 and
/// Optional Step 1 override to 26-28pt).
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

/// Italic system-serif hero title matching the v0.9 wizard spec.
struct WizardItalicTitle: View {
    let text: String
    var size: CGFloat = 32

    var body: some View {
        Text(text)
            .font(JotType.displaySerif(size))
            .tracking(-0.6)
            .foregroundStyle(Color.jotPageInk)
            .multilineTextAlignment(.center)
            .lineSpacing(1.05)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 15pt regular grey-ish body used beneath the title.
struct WizardBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(Color.jotPageInkSecondary)
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
                HStack(spacing: 0) {
                    Group {
                        if let onBack = header.onBack {
                            WizardBackButton(onBack: onBack)
                                // The 8pt padding on the back button widens
                                // the hit region — compensate so the visual
                                // stays flush to the left edge.
                                .padding(.leading, -8)
                        } else {
                            Color.clear
                                .frame(width: 32, height: 32)
                                .padding(8)
                                .padding(.leading, -8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    header.dots
                        .frame(maxWidth: .infinity, alignment: .center)

                    // The 8pt padding on the close button widens the hit
                    // region — compensate so the visual stays flush to
                    // the right edge.
                    WizardCloseButton(onClose: header.onClose)
                        .padding(.trailing, -8)
                        .frame(maxWidth: .infinity, alignment: .trailing)
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

            // Left-edge swipe-back catcher. The wizard is presented via
            // `.fullScreenCover`, so the system `interactivePopGesture`
            // (which requires a UINavigationController) is unavailable —
            // we recreate the gesture with a DragGesture pinned to the
            // leading 22pt of the panel. Layered LAST in the ZStack so it
            // gets first crack at the hit test inside its 22pt strip and
            // beats the inner ScrollView's gesture system there; outside
            // the strip the rest of the chrome is fully interactive.
            if let onBack = header.onBack {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 22)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 10, coordinateSpace: .local)
                                .onEnded { value in
                                    let startedNearLeadingEdge = value.startLocation.x < 22
                                    let draggedFarRight = value.translation.width > 60
                                    let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                                    if startedNearLeadingEdge && draggedFarRight && isHorizontal {
                                        onBack()
                                    }
                                }
                        )
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                }
                .accessibilityHidden(true)
            }
        }
    }
}

/// Header descriptor: which dots row to render plus the close + optional
/// back actions. `onBack` is nil on the Welcome step (no previous step
/// exists) and non-nil for every subsequent step so the user can always
/// undo a forward tap.
struct WizardHeader {
    enum DotsStyle {
        case core(current: Int)
        case optional(current: Int)
    }

    let style: DotsStyle
    let onClose: () -> Void
    let onBack: (() -> Void)?

    init(style: DotsStyle, onClose: @escaping () -> Void, onBack: (() -> Void)? = nil) {
        self.style = style
        self.onClose = onClose
        self.onBack = onBack
    }

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
