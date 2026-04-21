import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// Live Activity presentation for an in-flight Jot dictation and its
/// immediately-following command window.
///
/// The activity renders six phases (see `DictationAttributes.Phase`):
///   - `recording`    – pulsing red dot + monotonic elapsed-time counter
///   - `transcribing` – small spinner + "Transcribing…" label
///   - `processing`   – cancelable post-transcription command-resolution phase
///   - `cleaning`     – small spinner + "Polishing…" label
///   - `followUp`     – active 45-second follow-up window with countdown
///   - `finished*`    – legacy compatibility states retained for older
///     activity payloads; the current pipeline goes straight to `followUp`
@available(iOS 16.2, *)
struct JotLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DictationAttributes.self) { context in
            // Lock-screen / banner presentation (iPhones without Dynamic Island,
            // or when the phone is locked).
            LockScreenPill(phase: context.state.phase)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(.black.opacity(0.8))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ExpandedLeading(phase: context.state.phase)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ExpandedTrailing(phase: context.state.phase)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedBottom(phase: context.state.phase)
                }
            } compactLeading: {
                CompactLeading(phase: context.state.phase)
            } compactTrailing: {
                CompactTrailing(phase: context.state.phase)
            } minimal: {
                MinimalIndicator(phase: context.state.phase)
            }
            // Amber (Ledger brand CRT-phosphor) rather than system red so
            // the Dynamic Island trailing keyline *reads as Jot* instead
            // of "generic iOS recording app." Crucially, we keep the
            // recording dot itself red inside `StatusBadge` — that's the
            // iOS-wide convention nobody should break. Amber is the paint
            // around the glass, red is still the bulb behind it.
            .keylineTint(JotBrand.amber)
        }
    }
}

/// Brand tokens shared by widget surfaces. Mirrors the in-app Ledger
/// palette so the Live Activity, the app icon, and the main surface all
/// speak the same colour language. If these drift out of sync, the
/// product stops feeling like one thing — so they're co-located here.
@available(iOS 16.2, *)
enum JotBrand {
    /// Warm CRT phosphor amber — the single Ledger accent. Hex `#FFB81A`.
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.10)
}

// MARK: - Lock-screen presentation

@available(iOS 16.2, *)
private struct LockScreenPill: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(phase: phase)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("Jot")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                PrimaryLabel(phase: phase)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 8)

            TrailingDetail(phase: phase)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dynamic Island expanded regions

@available(iOS 16.2, *)
private struct ExpandedLeading: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        HStack(spacing: 8) {
            StatusBadge(phase: phase)
                .frame(width: 22, height: 22)
            Text("Jot")
                .font(.headline)
                .foregroundStyle(.primary)
        }
    }
}

@available(iOS 16.2, *)
private struct ExpandedTrailing: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        TrailingDetail(phase: phase)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.white)
    }
}

@available(iOS 16.2, *)
private struct ExpandedBottom: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        switch phase {
        case .recording:
            // Interactive stop button. Wired to `StopDictationIntent` — a
            // `LiveActivityIntent` that iOS 18+ promotes into the main-app
            // process to drive the exact same stop→transcribe→clipboard
            // pipeline that a second Action Button press runs. This is
            // what gives the user a direct stop affordance from the pill
            // itself (finger on the Dynamic Island) instead of having to
            // reach back up to the Action Button, which is especially
            // useful when the app is not open and the Action Button is
            // already bound to something else.
            Button(intent: StopDictationIntent()) {
                Label("Stop", systemImage: "stop.fill")
            }
            .tint(.red)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .transcribing:
            PrimaryLabel(phase: phase)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .processing:
            Button(intent: CancelPostProcessingIntent()) {
                Label("Cancel", systemImage: "xmark")
            }
            .tint(JotBrand.amber)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .cleaning:
            Button(intent: CancelPostProcessingIntent()) {
                Label("Cancel", systemImage: "xmark")
            }
            .tint(JotBrand.amber)
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
        case .followUp:
            VStack(alignment: .leading, spacing: 2) {
                Text("Follow-up window")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Say a command or record again")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .finished, .finishedCommand:
            EmptyView()
        }
    }
}

// MARK: - Dynamic Island compact / minimal

@available(iOS 16.2, *)
private struct CompactLeading: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        StatusBadge(phase: phase)
            .frame(width: 18, height: 18)
    }
}

@available(iOS 16.2, *)
private struct CompactTrailing: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        TrailingDetail(phase: phase)
            .font(.caption2.monospacedDigit().weight(.medium))
            .foregroundStyle(.white)
    }
}

@available(iOS 16.2, *)
private struct MinimalIndicator: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        StatusBadge(phase: phase)
    }
}

// MARK: - Shared sub-views

@available(iOS 16.2, *)
private struct StatusBadge: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        switch phase {
        case .recording:
            Circle()
                .fill(Color.red)
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        case .transcribing, .processing, .cleaning:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
        case .followUp:
            Circle()
                .fill(JotBrand.amber)
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
        case .finished:
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .foregroundStyle(.green)
        case .finishedCommand:
            // Same green-check terminal badge for the command outcome — the
            // user got their text on the clipboard; the distinction between
            // "fresh dictation" and "command applied" lives in the text
            // labels (`PrimaryLabel` / `ExpandedBottom`), not the status
            // badge. Using a different glyph here would add visual noise
            // without earning its cognitive cost.
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .foregroundStyle(.green)
        }
    }
}

@available(iOS 16.2, *)
private struct PrimaryLabel: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        switch phase {
        case .recording:
            Text("Recording…")
        case .transcribing:
            Text("Transcribing…")
        case .processing:
            Text("Processing…")
        case .cleaning:
            Text("Polishing…")
        case .followUp:
            Text("Follow-up")
        case .finished(let preview):
            Text(previewLabel(for: preview))
        case .finishedCommand(let instruction, let preview):
            Text(commandLabel(instruction: instruction, preview: preview))
        }
    }

    private func previewLabel(for preview: String) -> String {
        let snippet = String(preview.prefix(40))
        return snippet.isEmpty
            ? "Copied to clipboard"
            : "Copied to clipboard · \(snippet)"
    }

    private func commandLabel(instruction: String, preview: String) -> String {
        // Tighter budget than `previewLabel` because the instruction can
        // itself be long. Truncate the instruction to 28 and the preview
        // snippet to 22 so the total stays comparable to the fresh
        // dictation pill; iOS ellipsizes automatically if the composed
        // string still overflows.
        let trimmedInstruction = String(instruction.prefix(28))
        let trimmedPreview = String(preview.prefix(22))
        if trimmedPreview.isEmpty {
            return "Command: \(trimmedInstruction)"
        }
        return "Command: \(trimmedInstruction) · \(trimmedPreview)"
    }
}

/// Trailing cell: a live elapsed-time counter while recording, a static hint
/// otherwise. Using `Text(timerInterval:)` means the system drives the
/// per-second update without us pushing activity updates, which is the
/// recommended pattern per the ActivityKit docs.
@available(iOS 16.2, *)
private struct TrailingDetail: View {
    let phase: DictationAttributes.Phase

    var body: some View {
        switch phase {
        case .recording(let startedAt):
            Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
        case .transcribing:
            Text("…")
        case .processing:
            Text("…")
        case .cleaning:
            Text("…")
        case .followUp(let expiresAt):
            Text(timerInterval: Date.now...expiresAt, countsDown: true)
        case .finished:
            Text("Done")
        case .finishedCommand:
            // Same "Done" trailing for the command outcome — the
            // fresh-vs-command distinction is communicated in the primary
            // label column, not the trailing. Splitting the trailing text
            // ("Edited" vs "Done") was considered and rejected: it'd force
            // the user to read two columns to understand what happened,
            // whereas the primary label already says it in one ("Command:
            // <instruction> · <preview>").
            Text("Done")
        }
    }
}
