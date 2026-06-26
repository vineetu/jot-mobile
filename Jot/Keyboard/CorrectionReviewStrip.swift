import SwiftUI

/// Keyboard-side correction quick-review surface (adaptive vocabulary §).
///
/// After a saved dictation the MAIN APP publishes a small set of "asks"
/// (≤3 highest-value gated words worth reviewing) into the App-Group suite,
/// keyed by the dictation's `sessionID` (`CorrectionBridge.publishAsks`). The
/// keyboard reads them post-paste and renders this strip to let the owner
/// adjudicate each ask with a single tap. Verdicts are ENQUEUED back into the
/// App Group (`CorrectionBridge.enqueueVerdict`); the main app drains them when
/// it next becomes active and applies them into provenance + `CorrectionStore`.
///
/// **TEACH-ONLY.** This strip never edits the host app's already-pasted text —
/// the `adjustTextPosition` re-edit path is fragile (a research pass confirmed
/// teach-only). It only collects "did Jot guess right?" signal for learning.
///
/// Structural twin of `WarmHoldNudgeStrip` (WS-F): it takes over the strip slot
/// (`.frame(height: 129)` — every strip variant is pinned to 129pt or the keys
/// reflow), rebuilds the same Liquid Glass recipe from keyboard-available
/// tokens (the app-only `JotDesign.Surface` tokens can't link here), and routes
/// every mutating action back through controller callbacks. Unlike the warm-hold
/// nudge (whose timer is app-owned), this strip owns its own stage machine and
/// auto-dismiss timers because the keyboard drives the whole review flow.
struct CorrectionReviewStrip: View {
    let asks: [CorrectionBridge.Ask]
    /// Total unresolved proposals on the transcript (not just the ≤3 asks) — for
    /// the Done stage's "N more guesses are on the transcript in Jot." line.
    let totalUnresolved: Int
    let reduceMotion: Bool
    let feedback: KeyboardFeedback
    /// (recordKey, verdict) where verdict is "term" | "original".
    var onVerdict: (String, String) -> Void
    /// Dismiss → return the strip slot to recents (teach mode) OR "done, paste the
    /// resolved text now" (hold mode).
    var onFinished: () -> Void

    /// **HOLD mode (ask-before-paste, Thread 2).** When true the deck is GATING the
    /// paste, not teaching post-paste: it starts straight at the cards (no nudge
    /// stage), shows a per-card 10s countdown ring, offers "Stop asking", and on
    /// completion `onFinished` means "paste the resolved text". First-card idle with
    /// zero engagement → skip-all + finish (paste defaults). Default false = the
    /// original post-paste teach strip, unchanged.
    var holdMode: Bool = false
    /// Hold mode only: owner tapped "Stop asking" on this ask (keyboard-only suppress).
    var onStopAsking: (String) -> Void = { _ in }

    /// Matches the recents / streaming / warm-hold-nudge card height so toggling
    /// the strip in and out of the slot doesn't reflow the keyboard layout.
    private static let stripHeight: CGFloat = 129

    private enum Stage {
        case nudge
        case review
        case done
        case idle
    }

    @State private var stage: Stage = .nudge
    @State private var index = 0
    /// Per-ask transient feedback — the resolved consequence parts (bold lead +
    /// rest), matching the app's resolved copy; nil while choosing.
    @State private var verdictFeedback: (strong: String, rest: String)?
    /// Verdicts given in THIS keyboard session — subtracted from `totalUnresolved`
    /// for the Done-stage "N more" count.
    @State private var verdictsGiven = 0
    @State private var appeared = false
    /// Hold mode: has the owner interacted with ANY card yet? Gates the first-card
    /// idle behavior — zero engagement on card 1 → skip-all (don't march them
    /// through 3×10s); once engaged, an idle timeout skips only the current card.
    @State private var hasEngaged = false

    /// Remaining unresolved after this session's verdicts (clamped at 0).
    private var remainingUnresolved: Int { max(0, totalUnresolved - verdictsGiven) }

    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Self.stripHeight)
            .background(glassSurface)
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .inset(by: 0.5)
                    .stroke(Color.jotKeyboardGlassHighlight, lineWidth: 0.5)
                    .blendMode(.plusLighter)
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 4)
            .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.96))
            .opacity(appeared ? 1 : 0)
            .onAppear {
                // Hold mode gates the paste — skip the "Review?" nudge and show the
                // cards immediately (the user is waiting for their text to land).
                if holdMode, stage == .nudge { stage = .review }
                // Ground-truth that the strip actually rendered (not just the flag).
                DiagnosticsLog.record(source: "keyboard", category: .vocabularyGate,
                    message: holdMode ? "hold-deck rendered" : "nudge rendered",
                    metadata: ["asks": "\(asks.count)"])
                withAnimation(
                    reduceMotion
                        ? .easeOut(duration: 0.2)
                        : .spring(response: 0.42, dampingFraction: 0.8)
                ) {
                    appeared = true
                }
            }
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
        case .nudge:
            nudgeStage
        case .review:
            reviewStage
        case .done:
            doneStage
        case .idle:
            // Terminal — nothing renders (controller drops the strip slot on
            // `onFinished`); empty keeps the frame stable during the swap.
            Color.clear
        }
    }

    // MARK: - Nudge

    private var nudgeStage: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)
            Text("Jot guessed on \(asks.count) word\(asks.count == 1 ? "" : "s").")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundStyle(Color.jotKeyboardActionsInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                PressButton(reduceMotion: reduceMotion) {
                    feedback.systemClick()
                    feedback.selectionTick()
                    stage = .review
                } label: {
                    Text("Review")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 17)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Self.pillTopBlue, Color.jotKeyboardAccentDeep],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .accessibilityLabel("Review Jot's guesses")

                PressButton(reduceMotion: reduceMotion) {
                    feedback.systemClick()
                    onFinished()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.jotKeyboardStreamText)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(Color.jotKeyboardKeyFill)
                        )
                        .contentShape(Circle())
                }
                .accessibilityLabel("Dismiss")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            // 10s passive auto-dismiss — cancelled implicitly by the stage check
            // (if the user tapped Review/×, `stage` is no longer `.nudge`).
            Task {
                try? await Task.sleep(for: .seconds(10))
                if stage == .nudge { onFinished() }
            }
        }
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewStage: some View {
        if index < asks.count {
            let ask = asks[index]
            VStack(alignment: .leading, spacing: 10) {
                // Spoken context with the gated word emphasized — reads as
                // "what you said". The gated word is the one that ended up in
                // text (applied → term, kept → original). Hold mode tucks the
                // per-card 10s countdown ring into the trailing space here.
                HStack(alignment: .top, spacing: 8) {
                    spokenLine(for: ask)
                        // Cap to keep a long snippet from growing the 129pt card —
                        // shrink rather than wrap (matches the chips' behavior).
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if holdMode {
                        CountdownRing(seconds: 10, reduceMotion: reduceMotion)
                            .frame(width: 22, height: 22)
                    }
                }

                Spacer(minLength: 0)

                if let verdictFeedback {
                    // Resolved consequence line (bold lead + rest), matching the
                    // app's resolved copy. Base dwell 950ms (set in wordChip).
                    (Text(verdictFeedback.strong)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundColor(Color.jotKeyboardKeyInk)
                     + Text(verdictFeedback.rest)
                        .font(.system(size: 13.5))
                        .foregroundColor(Color.jotKeyboardStreamText))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                } else {
                    HStack(spacing: 8) {
                        // Original first, then term.
                        wordChip(
                            word: ask.original,
                            inText: ask.outcome == "kept",
                            verdict: "original",
                            ask: ask
                        )
                        wordChip(
                            word: ask.term,
                            inText: ask.outcome == "applied",
                            verdict: "term",
                            ask: ask
                        )

                        Spacer(minLength: 0)

                        // Hold mode: "Stop asking" replaces "Skip" (UX review §e).
                        // Teach mode keeps "Skip" exactly as before.
                        if holdMode {
                            PressButton(reduceMotion: reduceMotion) {
                                feedback.systemClick()
                                hasEngaged = true
                                onStopAsking(ask.recordKey)
                                advance()
                            } label: {
                                Text("Stop asking")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color.jotKeyboardStreamText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Stop asking about this word")
                            .accessibilityHint("Jot won't ask about \"\(ask.original)\" again. You can still review it on the transcript in Jot.")
                        } else {
                            PressButton(reduceMotion: reduceMotion) {
                                feedback.systemClick()
                                advance()
                            } label: {
                                Text("Skip")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(Color.jotKeyboardStreamText)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 6)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Skip this word")
                        }

                        Text("\(index + 1) of \(asks.count)")
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Color.jotKeyboardStreamText.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Re-key on the ask so context + chips animate per-ask if motion is on.
            .id(index)
            // Hold mode: start this card's idle countdown (auto-skip / skip-all).
            .onAppear { startCardCountdown(for: index) }
        } else {
            Color.clear
        }
    }

    /// "spoken" context: SF Pro 15.5 muted before/after (same face as the
    /// streaming strip), the gated word in key-ink. Native system font — no
    /// bundled font needed in the keyboard target (migrated per issue #4).
    private func spokenLine(for ask: CorrectionBridge.Ask) -> Text {
        let gated = ask.outcome == "applied" ? ask.term : ask.original
        let face = Font.system(size: 15.5, weight: .regular, design: .default)
        let before = Text(ask.contextBefore)
            .font(face)
            .foregroundColor(Color.jotKeyboardStreamText)
        // Dashed underline on the gated word (handoff `.kbm-word`). `Text.underline`
        // (iOS 16+) carries a per-run dash pattern; the 1.5px weight isn't settable
        // (renders ~1px) — accepted, same as the transcript marks.
        let word = Text(gated)
            .font(face)
            .foregroundColor(Color.jotKeyboardKeyInk)
            .underline(true, pattern: .dash, color: Color.jotKeyboardStreamText)
        let after = Text(ask.contextAfter)
            .font(face)
            .foregroundColor(Color.jotKeyboardStreamText)
        return before + word + after
    }

    private func wordChip(word: String, inText: Bool, verdict: String, ask: CorrectionBridge.Ask) -> some View {
        PressButton(reduceMotion: reduceMotion) {
            feedback.systemClick()
            feedback.selectionTick()
            hasEngaged = true   // hold mode: a chip tap counts as engagement
            onVerdict(ask.recordKey, verdict)
            verdictsGiven += 1
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2)) {
                verdictFeedback = Self.resolvedParts(ask, verdict: verdict)
            }
            Task {
                try? await Task.sleep(for: .milliseconds(950))
                advance()
            }
        } label: {
            HStack(spacing: 6) {
                Text(word)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotKeyboardKeyInk)
                    // Never wrap a word mid-word in the cramped strip row — keep it
                    // on one line, shrinking slightly if a name is long.
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                if inText, !holdMode {
                    Text("IN TEXT")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.jotKeyboardStreamText.opacity(0.8))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.jotKeyboardGlassHighlight.opacity(0.6))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous).fill(Color.jotKeyboardKeyFill)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.jotKeyboardGlassHairline, lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .accessibilityLabel(inText ? "\(word), in text" : word)
    }

    // MARK: - Done

    private var doneStage: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.jotKeyboardAccentDeep)
            Text(holdMode ? "All set." : "All reviewed.")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotKeyboardActionsInk)
                .multilineTextAlignment(.center)
            if remainingUnresolved > 0 {
                Text("\(remainingUnresolved) more "
                    + (remainingUnresolved == 1 ? "guess is" : "guesses are")
                    + " on the transcript in Jot.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.jotKeyboardStreamText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            Task {
                // Hold mode gates the paste — don't make the user stare at a
                // checkmark; finish fast so the (resolved) text lands.
                try? await Task.sleep(for: .seconds(holdMode ? 0.9 : 2.2))
                onFinished()
            }
        }
    }

    // MARK: - Flow

    private func advance() {
        verdictFeedback = nil
        index += 1
        if index >= asks.count {
            stage = .done
        }
    }

    /// Hold mode: the per-card 10s idle timeout. Drives the auto-skip independently
    /// of the (cosmetic) ring animation, so Reduce Motion still auto-advances. Fires
    /// only if still on this exact card and not mid-resolve. First card with zero
    /// engagement → skip-all (paste defaults); otherwise skip just this card.
    private func startCardCountdown(for cardIndex: Int) {
        guard holdMode else { return }
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard stage == .review, index == cardIndex, verdictFeedback == nil else { return }
            if !hasEngaged, cardIndex == 0 {
                index = asks.count
                stage = .done
            } else {
                advance()
            }
        }
    }

    /// Resolved consequence copy — VERBATIM the app's terse `CorrectionCopy.resolvedParts`
    /// (duplicated because `CorrectionCopy` lives in the App target and can't link
    /// into the keyboard; keep the two in lockstep — see
    /// docs/plans/correction-review-surface-parity.md). One deliberate word swap:
    /// the pane says "applied here." because it edits the text on the spot; the
    /// keyboard's edit lands in Jot later, so "here" is dropped.
    private static func resolvedParts(_ ask: CorrectionBridge.Ask, verdict: String) -> (strong: String, rest: String) {
        let applied = (ask.outcome == "applied")
        if verdict == "term" {
            return applied
                ? (ask.term, " confirmed.")
                : (ask.term, " applied.")
        }
        return applied
            ? (ask.original, " restored.")
            : (ask.original, " kept.")
    }

    // MARK: - Chrome

    // Hardcoded brand blue top stop — identical to the keyboard's Dictate pill
    // so the primary pill reads as the same surface across modes.
    private static let pillTopBlue = Color(red: 0 / 255, green: 122 / 255, blue: 255 / 255)

    /// Same Liquid Glass recipe as the recents / streaming / warm-hold cards.
    @ViewBuilder
    private var glassSurface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.jotKeyboardGlassFill1, Color.jotKeyboardGlassFill2],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
    }
}

/// Press-scale wrapper (0.96 / 0.12s) shared by every interactive control in
/// the strip; honours Reduce Motion by skipping the scale.
private struct PressButton<Label: View>: View {
    let reduceMotion: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    @State private var pressed = false

    var body: some View {
        Button(action: action) { label() }
            .buttonStyle(.plain)
            .scaleEffect(reduceMotion ? 1 : (pressed ? 0.96 : 1))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in pressed = true }
                    .onEnded { _ in pressed = false }
            )
    }
}

/// Cosmetic per-card countdown ring for the hold deck — a brand-blue arc that
/// depletes clockwise over `seconds`. Purely visual; the actual idle timeout is
/// driven by `CorrectionReviewStrip.startCardCountdown`, so Reduce Motion (static
/// full ring, no sweep) still auto-advances. Re-created per card by the parent's
/// `.id(index)`, so it restarts each time.
private struct CountdownRing: View {
    let seconds: Double
    let reduceMotion: Bool
    @State private var trim: CGFloat = 1

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.jotKeyboardGlassHairline, lineWidth: 2)
            Circle()
                .trim(from: 0, to: trim)
                .stroke(Color.jotKeyboardAccentDeep,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear {
            guard !reduceMotion else { return }   // static full ring
            withAnimation(.linear(duration: seconds)) { trim = 0 }
        }
        .accessibilityHidden(true)
    }
}
