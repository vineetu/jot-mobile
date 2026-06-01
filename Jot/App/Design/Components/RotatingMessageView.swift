//
//  RotatingMessageView.swift
//  Jot
//
//  UX-overhaul round 2 — WS-F shared micro-messaging engine.
//  See: docs/plans/ux-overhaul-round2.md §8 (WS-F) + §9 R19.
//
//  One rotation engine, several configured instances (different pool / dwell /
//  ordering). Two true rotators use it this cycle:
//    - Home header CTA — shuffled, ~8s dwell, cross-dissolve + small rise.
//    - Hero freed-top-space (keyboard path) — sequenced (it tells a story),
//      ~5s dwell, opacity-only fade.
//  The warm-hold nudge is deliberately NOT built on this (R19 — it's one-shot,
//  no rotation); see `WarmHoldNudgeView`.
//

import SwiftUI

/// Cross-fading micro-message rotator. Cycles through `messages`, holding each
/// for `dwell` seconds. When `sequenced` is `false` the pool is shuffled once
/// at appear (per-instance order); when `true` it plays in declared order
/// (the hero "story" beats H1→H4).
///
/// Accessibility: under Reduce Motion the auto-advance freezes to a single
/// stable line (the first message) and the only transition is a plain
/// cross-fade — no rise, no perpetual motion (WCAG 2.2.2). Rotation also
/// pauses while the view is off-screen (`.onDisappear`) so a backgrounded /
/// scrolled-away instance doesn't burn timers.
///
/// Layout: reserves a fixed 2-line minimum height so swapping a 1-line message
/// for a 2-line one doesn't reflow the surrounding chrome. Visual specifics
/// (exact curve, rise distance) are intentionally rough — tune later per the
/// plan; behavior correctness first.
struct RotatingMessageView: View {
    let messages: [String]
    let dwell: TimeInterval
    /// `true` → declared order (story beats); `false` → shuffled once on appear.
    let sequenced: Bool

    /// Per-line typography. Defaults to the editorial serif-italic face used by
    /// the home CTA; call sites can override for the hero top-space copy.
    var font: Font = JotType.displaySerif(20)
    /// Line color. Defaults to the secondary page ink so the message reads as
    /// supporting copy, not a headline. Override at the call site as needed.
    var color: Color = .jotPageInkSecondary
    var alignment: TextAlignment = .leading
    /// Upward travel of the incoming line under normal motion. Zeroed under
    /// Reduce Motion (plain cross-fade only).
    var rise: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The order we actually play — declared or shuffled, resolved once on
    /// appear so a re-render doesn't reshuffle mid-rotation.
    @State private var order: [Int] = []
    @State private var cursor: Int = 0
    /// Drives `.onDisappear` teardown so the timer task stops off-screen.
    @State private var isVisible = false

    var body: some View {
        // Guard an empty pool — render nothing rather than crash on `order[0]`.
        let current = currentMessage

        Text(current)
            .font(font)
            .foregroundStyle(color)
            .multilineTextAlignment(alignment)
            .frame(
                maxWidth: .infinity,
                minHeight: twoLineMinHeight,
                alignment: frameAlignment
            )
            .id(current)                       // force a fresh view per swap so
                                                // the transition actually fires
            .transition(transition)
            .animation(.easeInOut(duration: 0.45), value: current)
            .onAppear {
                isVisible = true
                if order.isEmpty { resolveOrder() }
                // Reduce Motion: stay on the single stable line, no advance.
                guard !reduceMotion else { return }
                Task { await rotate() }
            }
            .onDisappear { isVisible = false }
            .accessibilityElement()
            .accessibilityLabel(Text(current))
    }

    // MARK: - Derived

    private var currentMessage: String {
        guard !messages.isEmpty else { return "" }
        guard !order.isEmpty, cursor < order.count else { return messages[0] }
        return messages[order[cursor]]
    }

    /// Opacity-only under Reduce Motion; otherwise a cross-fade with a small
    /// upward rise on insertion.
    private var transition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(y: rise)),
            removal: .opacity
        )
    }

    /// Two lines of the current font, used as the reserved min height so the
    /// container doesn't reflow when message length changes.
    private var twoLineMinHeight: CGFloat {
        // Rough reservation — a 2-line box at ~22pt leading. Tunable later;
        // the plan flags pixel sizes as adjustable.
        44
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading:  return .leading
        case .center:   return .center
        case .trailing: return .trailing
        }
    }

    // MARK: - Rotation

    private func resolveOrder() {
        let indices = Array(messages.indices)
        order = sequenced ? indices : indices.shuffled()
        cursor = 0
    }

    /// Advance the cursor every `dwell` seconds while on-screen. Stops cleanly
    /// when the view disappears (the loop re-checks `isVisible`), so no stray
    /// timer survives a scroll-away.
    private func rotate() async {
        // Single message → nothing to rotate.
        guard messages.count > 1 else { return }
        while isVisible {
            try? await Task.sleep(for: .seconds(dwell))
            guard isVisible else { break }
            withAnimation {
                cursor = (cursor + 1) % order.count
            }
        }
    }
}
