//
//  WarmHoldNudgeView.swift
//  Jot
//
//  UX-overhaul round 2 — WS-F warm-hold switching nudge (the runtime nudge,
//  NOT the parked wizard opt-in panel).
//  See: docs/plans/ux-overhaul-round2.md §4 (detection math), §8 (copy),
//  §9 R10 / R17 / R19.
//
//  One-shot affordance (R19 — deliberately NOT built on `RotatingMessageView`,
//  which is for true rotators). It renders off the App-Group
//  `warmHoldNudgeShouldShow` projection that the app sets once the
//  record-and-bounce streak crosses threshold (§4). Two one-tap actions, no
//  confirmation:
//    - "Keep mic ready"        → flips warm hold ON (the satisfied terminal).
//    - "Don't show this again" → sets the permanent suppression flag.
//  Either action (and the ~6s passive auto-hide) clears the shouldShow flag and
//  posts `warmHoldNudgeChanged` so the other process re-reads. Passive auto-hide
//  is NOT suppression — it re-shows on the next qualifying burst (§4).
//

import SwiftUI

/// Inline warm-hold switching nudge. Spring-in, auto-hide ~6s if untouched.
/// Place on whichever surface the user just stopped on (hero freed-top-space
/// or — via its App-Group-boolean twin — the keyboard strip). This SwiftUI
/// view is the app-side renderer; the keyboard renders its own equivalent off
/// the same boolean (it can't link this file's app-only chrome freely, but the
/// state contract is shared).
struct WarmHoldNudgeView: View {
    /// Called after the user picks either action OR the nudge auto-hides, so
    /// the host can drop it from the view tree. The state writes + cross-process
    /// post happen inside this view; the closure is purely a "remove me" signal.
    var onResolve: () -> Void = {}

    /// Auto-hide window — passive ignore ≠ suppression (§4), so this just hides;
    /// it does NOT set `warmHoldNudgeSuppressed`.
    private let autoHideAfter: TimeInterval = 6

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    /// Guards against double-resolution (an action tap racing the auto-hide).
    @State private var resolved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Headline — R17: softened so it doesn't overpromise "skip the wait"
            // for the immediately-following dictation (accepting only warms the
            // NEXT session).
            Text("Bouncing back and forth to dictate? Keep the mic ready so the next one starts instantly.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button(action: acceptKeepMicReady) {
                    Text("Keep mic ready")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [.jotCoralTop, .jotCoralBottom],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Keep mic ready"))

                Button(action: dismissDontShowAgain) {
                    Text("Don't show this again")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Don't show this again"))

                Spacer(minLength: 0)
            }
        }
        .padding(JotDesign.Spacing.cardPaddingH)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(JotDesign.Surface.regular.modifier(cornerRadius: JotDesign.Spacing.cardRadiusV09))
        // Spring-in (rough — tunable). Reduce Motion → no scale/offset, plain
        // fade.
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.92))
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(
                reduceMotion
                    ? .easeOut(duration: 0.2)
                    : .spring(response: 0.42, dampingFraction: 0.78)
            ) {
                appeared = true
            }
            scheduleAutoHide()
        }
    }

    // MARK: - Actions

    /// Accept: flip warm hold ON (the satisfied terminal — never nudges again).
    private func acceptKeepMicReady() {
        AppGroup.warmHoldEnabled = true
        clearAndPost()
        resolve()
    }

    /// Dismiss: permanent one-tap suppression (no confirm, §4).
    private func dismissDontShowAgain() {
        AppGroup.warmHoldNudgeSuppressed = true
        clearAndPost()
        resolve()
    }

    /// Passive auto-hide: clears the show flag (so a stale projection doesn't
    /// resurrect the nudge) and posts, but does NOT set suppression — it
    /// re-shows next qualifying burst (§4).
    private func autoHide() {
        clearAndPost()
        resolve()
    }

    // MARK: - Plumbing

    /// Clear the App-Group projection + notify the other process to re-read.
    private func clearAndPost() {
        AppGroup.warmHoldNudgeShouldShow = false
        CrossProcessNotification.post(name: CrossProcessNotification.warmHoldNudgeChanged)
    }

    private func resolve() {
        guard !resolved else { return }
        resolved = true
        onResolve()
    }

    private func scheduleAutoHide() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoHideAfter))
            guard !resolved else { return }
            autoHide()
        }
    }
}

#Preview("Warm-hold switching nudge") {
    ZStack {
        Color.jotPageBase
            .ignoresSafeArea()

        WarmHoldNudgeView()
            .padding(JotDesign.Spacing.pageGutter)
    }
}
