import SwiftUI

/// Hold-mode wiring for `CorrectionReviewStrip`: the hub's deck snapshot in, the
/// deck's token-fenced actions out. Its presence IS hold mode.
///
/// Every action carries the `AskDeckToken` the strip was RENDERED with, not
/// whatever deck the hub happens to hold when the tap lands. A strip that
/// SwiftUI has not finished tearing down, or a ghost controller's copy of it,
/// therefore hands the hub a token it can recognise as stale and drop — the
/// alternative (a parameterless callback into a process singleton) is exactly
/// how a stale surface came to drive the live deck.
struct AskDeckBinding {
    let snapshot: AskDeckSnapshot
    /// (token, recordKey, "term" | "original" | "alt0")
    let verdict: (AskDeckToken, String, String) -> Void
    let stopAsking: (AskDeckToken, String) -> Void
    let skipCard: (AskDeckToken, String) -> Void
    let skipAll: (AskDeckToken) -> Void
    let finished: (AskDeckToken) -> Void

    var token: AskDeckToken { snapshot.token }
    var index: Int { snapshot.index }
    var hasEngaged: Bool { snapshot.hasEngaged }
    var answered: Int { snapshot.answered }
}

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
/// nudge (whose timer is app-owned), this strip drives the review flow itself.
///
/// **Two modes.** Post-paste TEACH mode owns its own stage machine and dwell
/// timers in view-local state, which is fine — nothing is riding on it. HOLD mode
/// (`deck != nil`, ask-before-paste) owns NONE of that: it is gating a real
/// pending paste, and view-local progress died with the view while the paste
/// lived on, so its progress comes from the hub's `ActiveDeck` and its actions go
/// back token-fenced. Its timers are `.task(id:)`, cancelled by the deck's own
/// progress rather than left running against whatever renders next.
struct CorrectionReviewStrip: View {
    let asks: [CorrectionBridge.Ask]
    /// Total unresolved proposals on the transcript (not just the ≤3 asks) — for
    /// the Done stage's "N more guesses are on the transcript in Jot." line.
    let totalUnresolved: Int
    let reduceMotion: Bool
    let feedback: KeyboardFeedback
    /// (recordKey, verdict) where verdict is "term" | "original" | "alt0"
    /// ("alt0" = the ask's alternate longer term, 3-option ask 2026-07-13).
    var onVerdict: (String, String) -> Void
    /// Dismiss → return the strip slot to recents (teach mode) OR "done, paste the
    /// resolved text now" (hold mode).
    var onFinished: () -> Void

    /// **HOLD mode (ask-before-paste).** Non-nil means the deck is GATING a paste,
    /// not teaching post-paste: it starts straight at the cards (no nudge stage),
    /// shows a per-card 10s countdown ring, offers "Stop asking", and on completion
    /// means "paste the resolved text". First-card idle with zero engagement →
    /// skip-all + finish (paste defaults). Nil = the post-paste teach strip,
    /// unchanged.
    ///
    /// F1: in hold mode this view owns NO progress. Which card is showing, what
    /// the owner has answered, and whether they have engaged all live in the hub's
    /// `ActiveDeck` and arrive through `deck.snapshot`; every action goes back out
    /// token-fenced. That is what lets a strip torn down mid-deck come back on the
    /// card it left off, instead of restarting and re-answering card 1 with a
    /// different word than the one the app already recorded.
    var deck: AskDeckBinding? = nil

    /// Matches the recents / streaming / warm-hold-nudge card height so toggling
    /// the strip in and out of the slot doesn't reflow the keyboard layout.
    private static let stripHeight: CGFloat = 129

    private enum Stage {
        case nudge
        case review
        case done
        case idle
    }

    /// TEACH-mode progress. In hold mode every one of these is ignored in favour
    /// of the hub snapshot (see `deck`) — a local copy is exactly what died with
    /// the view and restarted the deck.
    @State private var localStage: Stage = .nudge
    @State private var localIndex = 0
    @State private var localVerdictsGiven = 0
    @State private var localHasEngaged = false
    @State private var appeared = false

    private var holdMode: Bool { deck != nil }

    /// The card the deck is waiting on: hub-owned in hold mode (so a remount
    /// RESUMES here), view-local in teach mode.
    private var currentIndex: Int { deck?.index ?? localIndex }

    /// The card being drawn: the one the deck is waiting on.
    private var displayIndex: Int { currentIndex }

    private var hasEngaged: Bool { deck?.hasEngaged ?? localHasEngaged }

    private var verdictsGiven: Int { deck?.answered ?? localVerdictsGiven }

    /// Hold mode derives its stage from deck progress (no `.nudge` stage, and no
    /// stored `stage` that could disagree with the answers); teach mode keeps its
    /// own.
    private var stage: Stage {
        guard deck != nil else { return localStage }
        return currentIndex >= asks.count ? .done : .review
    }

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
                // Hold mode has no "Review?" nudge stage at all — `stage` derives
                // from deck progress, so a re-mounted strip lands on the first
                // unanswered card rather than at the top of the flow.
                // Ground-truth that the strip actually rendered (not just the flag).
                DiagnosticsLog.record(source: "keyboard", category: .vocabularyGate,
                    message: holdMode ? "hold-deck rendered" : "nudge rendered",
                    metadata: ["asks": "\(asks.count)",
                               "resumeAt": "\(currentIndex)"])
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
                    localStage = .review
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
        // 10s passive auto-dismiss. `.task` (not a free-floating `Task`) so it is
        // cancelled when this stage goes away, instead of surviving as an
        // unstructured timer that fires against whatever is on screen later.
        .task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, stage == .nudge else { return }
            onFinished()
        }
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewStage: some View {
        if displayIndex < asks.count {
            let ask = asks[displayIndex]
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

                HStack(spacing: 8) {
                    // Original first, then term, then (3-option ask) the
                    // alternate longer term when one fits the span —
                    // "cloud code" · "Claude" · "Claude Code".
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
                    if let altTerm = ask.altTerm {
                        wordChip(
                            word: altTerm,
                            inText: false,
                            verdict: "alt0",
                            ask: ask
                        )
                    }

                    Spacer(minLength: 0)

                    // Hold mode: "Stop asking" replaces "Skip" (UX review §e).
                    // Teach mode keeps "Skip" exactly as before.
                    if let deck {
                        PressButton(reduceMotion: reduceMotion) {
                            feedback.systemClick()
                            // "Stop asking" keeps the ORIGINAL word in the paste
                            // and teaches the app to stop offering this pair on
                            // the keyboard. One answer, two meanings — recorded
                            // once in the deck, so the paste and the app can't
                            // end up with different ideas of what was chosen.
                            deck.stopAsking(deck.token, ask.recordKey)
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
                            advanceTeach()
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

                    Text("\(displayIndex + 1) of \(asks.count)")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.jotKeyboardStreamText.opacity(0.7))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Re-key on the ask so context + chips animate per-ask if motion is on.
            .id(displayIndex)
            // Hold mode: this card's idle countdown. `.task(id:)` — NOT a
            // free-floating `Task` — so it is cancelled and restarted by the
            // deck's own progress, and dies with the view instead of firing
            // later against a card (or a deck) that is no longer there. The id
            // carries the deck GENERATION, so a countdown armed for a superseded
            // deck can never advance the live one.
            .task(id: cardCountdownKey) { await runCardCountdown() }
        } else {
            Color.clear
        }
    }

    /// "spoken" context: Fraunces italic 15.5 muted before/after (spoken voice =
    /// serif italic, same as the streaming strip), the gated word in key-ink.
    /// Fraunces is bundled + linkable in the keyboard target (see StreamingStrip).
    private func spokenLine(for ask: CorrectionBridge.Ask) -> Text {
        let gated = ask.outcome == "applied" ? ask.term : ask.original
        let serif = Font.custom(JotType.frauncesItalicText, size: 15.5)
        let before = Text(ask.contextBefore)
            .font(serif)
            .foregroundColor(Color.jotKeyboardStreamText)
        // Dashed underline on the gated word (handoff `.kbm-word`). `Text.underline`
        // (iOS 16+) carries a per-run dash pattern; the 1.5px weight isn't settable
        // (renders ~1px) — accepted, same as the transcript marks.
        let word = Text(gated)
            .font(serif)
            .foregroundColor(Color.jotKeyboardKeyInk)
            .underline(true, pattern: .dash, color: Color.jotKeyboardStreamText)
        let after = Text(ask.contextAfter)
            .font(serif)
            .foregroundColor(Color.jotKeyboardStreamText)
        return Text("\(before)\(word)\(after)")
    }

    private func wordChip(word: String, inText: Bool, verdict: String, ask: CorrectionBridge.Ask) -> some View {
        PressButton(reduceMotion: reduceMotion) {
            feedback.systemClick()
            feedback.selectionTick()
            if let deck {
                // The hub records the answer (and advances) synchronously; a
                // record it has already answered is refused there, so a strip
                // that came back mid-deck cannot overwrite an earlier pick.
                deck.verdict(deck.token, ask.recordKey, verdict)
            } else {
                onVerdict(ask.recordKey, verdict)
                localVerdictsGiven += 1
                localHasEngaged = true
            }
            // No "you picked X" dwell (owner, 2026-09-30: with three or four
            // questions it paused a second on each to repeat what was just
            // tapped). The next card — or the paste — follows the tap at once.
            if !holdMode {
                withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .easeOut(duration: 0.2)) {
                    advanceTeach()
                }
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
        // F5: say what the tap actually does. The hold deck splices the pick into
        // the text it is about to paste; the post-paste strip is teach-only and
        // cannot touch text that already landed, so its hint must not imply it.
        .accessibilityHint(holdMode
            ? "Uses this word in the text Jot is about to paste."
            : "Records this as your preference for next time. The text already pasted isn't changed.")
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
        // Cancellable (`.task`, not a detached `Task`): a done-dwell that outlived
        // this stage would finish a deck that something else already resolved.
        .task {
            // Hold mode gates the paste — no dwell at all; the text lands the
            // moment the last card is answered. Teach mode (post-paste) keeps a
            // short "All reviewed." beat before the strip goes away.
            if !holdMode {
                try? await Task.sleep(for: .seconds(2.2))
            }
            guard !Task.isCancelled else { return }
            if let deck {
                deck.finished(deck.token)
            } else {
                onFinished()
            }
        }
    }

    // MARK: - Flow

    /// TEACH mode only — hold mode's progress is the hub's (`ActiveDeck.index`).
    private func advanceTeach() {
        localIndex += 1
        if localIndex >= asks.count {
            localStage = .done
        }
    }

    /// Identity of the countdown currently armed. Changing it cancels the old
    /// task and starts a fresh one: a new card or a new deck generation.
    /// Constant in teach mode, which has no
    /// per-card timeout (the countdown body returns immediately there).
    private var cardCountdownKey: String {
        guard let deck else { return "teach" }
        return "\(deck.token.generation)#\(currentIndex)"
    }

    /// Hold mode: the per-card 10s idle timeout. Drives the auto-skip independently
    /// of the (cosmetic) ring animation, so Reduce Motion still auto-advances.
    /// First card with zero engagement → skip-all (paste defaults); otherwise skip
    /// just this card. The hub re-checks the token, so a countdown that survives
    /// one run-loop too long still can't touch a deck that has moved on.
    private func runCardCountdown() async {
        guard let deck,
              currentIndex >= 0, currentIndex < asks.count else { return }
        let card = currentIndex
        let recordKey = asks[card].recordKey
        try? await Task.sleep(for: .seconds(10))
        guard !Task.isCancelled else { return }
        if !deck.hasEngaged, card == 0 {
            deck.skipAll(deck.token)
        } else {
            deck.skipCard(deck.token, recordKey)
        }
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
