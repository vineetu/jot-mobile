import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Live Activity presentation for an in-flight Jot dictation.
///
/// Renders four user-visible states (collapsed from `DictationAttributes.Phase`'s
/// engine phases per design.md §2):
///
///   - **Recording** — `.recording(startedAt:)` → static red dot + system-driven
///     elapsed-time counter. Compact and minimal stay text-free; expanded
///     center renders `lastWordsPreview` when toggle is on.
///   - **Transcribing** — `.transcribing | .processing | .cleaning` → circular
///     `ProgressView` + static `…` glyph. Engine-phase distinctions are not
///     user-visible; one label `"Transcribing"` for all three.
///   - **Done flash** — `.followUp | .finished | .finishedCommand` → green
///     check, no trailing column. Activity self-dismisses after 2.0s via
///     `Activity.end(_, dismissalPolicy: .after(...))` from app code.
///   - **Idle** — no activity, no DI surface.
///
/// Hard rules (design.md §4):
///   - No custom continuous animations. No `.repeatForever`, no `withAnimation`.
///   - The only motion is system-driven: switch-branch crossfade, `ProgressView`
///     spinner, `Text(timerInterval:)` tick.
///   - `Text(timerInterval:)` always passes `showsHours: false` — Apple's
///     default is `true` which renders `0:00:14` instead of `0:14`.
///
/// Privacy gate for `lastWordsPreview` (design.md §8.7):
///   1. **Structural** — only the expanded `.center` region and the lock-screen
///      banner's row 3 reference `state.lastWordsPreview`. Compact and minimal
///      cannot leak it.
///   2. **Runtime** — writer-side gate (in the streaming-writer, not the widget
///      body): when the toggle is off, the writer skips its `Activity.update`
///      call and `lastWordsPreview` stays `nil`. The widget renders nothing.
struct JotLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { context in
            // Lock-screen + banner presentation (§3.7: same view for both).
            LockScreenBanner(state: context.state, isStale: context.isStale)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(state: context.state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(state: context.state)
                }
                DynamicIslandExpandedRegion(.center) {
                    // Recording-state-only; toggle-gated via writer-side
                    // suppression (writer doesn't push when toggle is off, so
                    // `lastWordsPreview` stays `nil` and the region collapses).
                    ExpandedCenter(state: context.state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(state: context.state)
                }
            } compactLeading: {
                CompactLeading(state: context.state)
            } compactTrailing: {
                CompactTrailing(state: context.state)
            } minimal: {
                MinimalIndicator(state: context.state)
            }
            // Keyline tint is state-independent: amber for every phase. Per
            // design.md §9.1, varying the keyline per state would be over-
            // decorative motion; first-party Apple apps treat the keyline as
            // brand chrome, not a state indicator. State is communicated by
            // the dot/check inside the pill.
            .keylineTint(JotBrand.amber)
        }
    }
}

/// Brand tokens shared by widget surfaces. The CRT-phosphor amber is the
/// single Ledger accent; it appears on the keyline tint and nowhere else.
/// (Compare design.md §6: red is system-red live capture; green is system-
/// green completion; amber is brand chrome only, never replaces a system
/// semantic.)
enum JotBrand {
    /// Warm CRT phosphor amber — the single Ledger accent. Hex `#FFB81A`.
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.10)
}

// MARK: - Lock-screen / banner presentation
//
// Per design.md §3.7, lock-screen and banner share a single SwiftUI view
// (the first `ActivityConfiguration` closure). We do not fork copy for the
// two presentations — runtime-discriminating between them is not a documented
// capability.

private struct LockScreenBanner: View {
    let state: DictationAttributes.ContentState
    let isStale: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Leading: the state badge (red dot / spinner / amber dot / green
            // check). Sized small enough to read as a wordmark prefix.
            StateBadge(phase: state.phase)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                // Row 1: Jot wordmark.
                Text("Jot")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                // Row 2: state name (lowercase per Voice-Memos parity).
                Text(stateName(for: state.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Row 3 (recording-state-only, toggle-gated):
                // `lastWordsPreview`. Single line on lock-screen vs two lines
                // in expanded `.center` — banner has tighter vertical budget.
                // Conditionally included so empty doesn't render an empty
                // Text() row taking up vertical space (per §8.8).
                if shouldRenderTranscriptRow,
                   let preview = state.lastWordsPreview,
                   !preview.isEmpty {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Trailing: timer for recording; nothing for the other states
            // (transcribing has no useful clock; done flash has no duration
            // field on `ContentState` — see §3.5.4).
            LockScreenTrailing(phase: state.phase)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        }
        .opacity(isStale ? 0.55 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(stateName(for: state.phase)))
        .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    }

    private var shouldRenderTranscriptRow: Bool {
        if case .recording = state.phase { return true }
        return false
    }

    private func stateName(for phase: DictationAttributes.Phase) -> String {
        switch phase {
        case .recording:
            return "Recording"
        case .transcribing, .processing, .cleaning:
            return "Transcribing"
        case .followUp, .finished, .finishedCommand:
            return "Saved"
        }
    }
}

/// Lock-screen trailing column: count-up timer for recording; empty for
/// other states.
private struct LockScreenTrailing: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        switch phase {
        case .recording(let startedAt):
            Text(
                timerInterval: startedAt...Date.distantFuture,
                pauseTime: nil,
                countsDown: false,
                showsHours: false
            )
        case .transcribing, .processing, .cleaning,
             .followUp, .finished, .finishedCommand:
            EmptyView()
        }
    }
}

// MARK: - Dynamic Island expanded regions

/// Leading region: state badge + state-name label.
private struct ExpandedLeading: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        HStack(spacing: 8) {
            StateBadge(phase: state.phase)
                .frame(width: 14, height: 14)
            Text(stateName(for: state.phase))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(stateName(for: state.phase)))
    }

    private func stateName(for phase: DictationAttributes.Phase) -> String {
        switch phase {
        case .recording:
            return "Recording"
        case .transcribing, .processing, .cleaning:
            return "Transcribing"
        case .followUp, .finished, .finishedCommand:
            return "Saved & copied"
        }
    }
}

/// Trailing region: count-up timer for recording; empty for transcribing
/// and done flash (per §3.3.3 / §3.5.3).
private struct ExpandedTrailing: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording(let startedAt):
            Text(
                timerInterval: startedAt...Date.distantFuture,
                pauseTime: nil,
                countsDown: false,
                showsHours: false
            )
            .font(.title3.monospacedDigit().weight(.medium))
            .foregroundStyle(.white)
        case .transcribing, .processing, .cleaning,
             .followUp, .finished, .finishedCommand:
            EmptyView()
        }
    }
}

/// Center region: the live partial-transcript preview.
///
/// Per design.md §3.2.3 + §8.1: renders only when `state.phase == .recording`
/// AND `lastWordsPreview` is non-nil-non-empty. The toggle-off case lands
/// here as `lastWordsPreview == nil` (writer-side suppression) and the
/// region renders `EmptyView()`, so the expanded layout collapses to the
/// no-transcript shape (leading + trailing + bottom).
private struct ExpandedCenter: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        if case .recording = state.phase,
           let preview = state.lastWordsPreview,
           !preview.isEmpty {
            Text(preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }
}

/// Bottom region: state-dependent action / disclosure surface.
///
/// - Recording → full-width destructive Stop button.
/// - Transcribing → static "Working on it…" copy.
/// - Done flash → empty (the green check + "Saved & copied" leading carries
///   the meaning; the optional "Open in Jot" link was downgraded to
///   enhancement and depends on `jot://` URL scheme registration which we
///   already have, but per §3.5.3 a single tap on the DI/banner foregrounds
///   Jot at its default scene — which is the safe fallback).
private struct ExpandedBottom: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording:
            // Single full-width destructive button. No Cancel, no More — the
            // expanded view is glanceable and committed (design.md §3.2.3).
            Button(intent: StopDictationIntent()) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Stop recording")

        case .transcribing, .processing, .cleaning:
            // Static line; no shimmer (would risk the same Q1 cadence
            // problem as the rejected amplitude meter — see §3.3.3).
            Text("Working on it…")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)

        case .followUp, .finished, .finishedCommand:
            // Done flash expanded: the leading "Saved & copied" + green check
            // is the entire content. Trailing returns EmptyView (§3.5.3 — no
            // duration field on ContentState, and we refuse to fabricate one
            // from `Date.now - startedAt` at widget render time).
            //
            // The optional "Open in Jot" deep-link button is enhancement, not
            // core (§3.5.3 + reviewer Round-1 Issue 18). v1 omits it — the
            // user can tap the DI/banner to foreground Jot at its default
            // scene. A v1.x can add the explicit Link() button once
            // `jot://history/latest` lands.
            EmptyView()
        }
    }
}

// MARK: - Dynamic Island compact / minimal

/// Compact leading slot: a single small badge (~8 pt dot or 16 pt check).
private struct CompactLeading: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        StateBadge(phase: state.phase)
            .frame(width: 8, height: 8)
            .padding(.leading, 4)
    }
}

/// Compact trailing slot: timer for recording, static `…` for transcribing,
/// empty for done flash.
private struct CompactTrailing: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .recording(let startedAt):
            Text(
                timerInterval: startedAt...Date.distantFuture,
                pauseTime: nil,
                countsDown: false,
                showsHours: false
            )
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.white)
        case .transcribing, .processing, .cleaning:
            // Static ellipsis; no timeline-driven cycle (Q1 cadence risk).
            // The leading spinner already signals motion.
            Text("\u{2026}")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.55))
        case .followUp, .finished, .finishedCommand:
            EmptyView()
        }
    }
}

/// Minimal slot: shown when another Live Activity holds the leading. A
/// single 18 pt static glyph (per §3.2.2 / §3.3.2 / §3.4.2 / §3.5.2).
private struct MinimalIndicator: View {
    let state: DictationAttributes.ContentState

    var body: some View {
        StateBadge(phase: state.phase)
            .frame(width: 18, height: 18)
    }
}

// MARK: - Shared sub-views

/// State-dependent badge glyph used in compact leading, minimal, expanded
/// leading, and lock-screen leading. Static — no pulse, no breathing, no
/// amplitude bar (per design.md §3.2.1: "do not add a pulse without the Q1
/// spike landing first.").
///
/// Color crossfade between phases is handled by SwiftUI's automatic Color
/// interpolation when the `.fill` value changes between renders. We do not
/// compose a `ZStack` of opaque circles or wrap in `withAnimation`.
private struct StateBadge: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        switch phase {
        case .recording:
            Circle()
                .fill(Color(.systemRed))
                .overlay(
                    Circle().stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
        case .transcribing, .processing, .cleaning:
            // System circular spinner. The system manages its animation
            // cadence — we do not need a `TimelineView` wrapper, sidestepping
            // the Q1 cadence question that killed the amplitude meter.
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
                .controlSize(.mini)
        case .followUp, .finished, .finishedCommand:
            // Two-color SF Symbol: white check on green fill — the iOS-wide
            // "completed" semantic. `.symbolRenderingMode(.palette)` is what
            // lets `.foregroundStyle(.white, Color(.systemGreen))` apply two
            // distinct colors to the layered symbol.
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(.systemGreen))
        }
    }
}
