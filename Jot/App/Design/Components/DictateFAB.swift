//
//  DictateFAB.swift
//  Jot
//
//  Phase 3 of the UX overhaul — editorial home Dictate FAB.
//  See: Jot/tmp/ux-overhaul-plan.md §5.1 (Mockup 07).
//
//  Floating blue gradient pill button anchored to the bottom-center of the
//  editorial home. ~200pt × 64pt with a mic icon + "Dictate" label.
//  Invokes the caller-supplied tap action — in v1 the home flips a state
//  binding that drives `.navigationDestination(isPresented:)` so that the
//  manual FAB flow and the auto-nav (URL-bounce) flow share a single
//  destination and a recording in flight never causes a double-push.
//
//  The FAB is sized well above the 44pt HIG floor (64pt tall), so glass
//  blur is fine here — we layer a blue gradient on top of the surface
//  rather than relying on the `.regular` glass tier (which would dilute
//  the brand accent). The result reads as a blue gradient CTA with a soft
//  glass halo, matching the mockup.
//

import SwiftUI

/// Floating Dictate CTA shown on the editorial home (mockup 07). Invokes
/// `action` on tap; the home surface uses that to flip a state binding
/// that drives a `.navigationDestination(isPresented:)` push of
/// `RecordingHeroView`.
struct DictateFAB: View {
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressed = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 20, weight: .semibold))
                Text("Dictate")
                    .font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(minWidth: 200, minHeight: 64)
            .padding(.horizontal, 28)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotBlueTop,
                                Color.jotBlueBottom
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
            )
            .shadow(color: Color.jotBlueTop.opacity(0.35), radius: 18, x: 0, y: 10)
            .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 2)
            .scaleEffect(isPressed ? 0.97 : 1.0)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.12),
                value: isPressed
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel("Dictate")
        .accessibilityHint("Opens the recording surface")
        .accessibilityAddTraits(.isButton)
    }
}
