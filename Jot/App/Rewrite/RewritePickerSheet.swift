import Foundation
import SwiftUI
import os.log

/// Bottom-sheet rewrite picker (Mockup 10 / plan §6.1).
///
/// Presented from `TranscriptDetailView`'s Rewrite button when the AI rewrite
/// model is `.ready`. Lists the user's saved prompts as tappable rows; tap
/// fires the existing `LLMClient.rewrite(text:systemPrompt:)` path and
/// dismisses the sheet. The result-handling lifecycle (running / success /
/// error) is owned by the host detail view — this sheet is a picker only.
///
/// ## Why a sheet (not a `confirmationDialog`)
///
/// Mockup 10 calls for a 360pt drawer with grabber, multi-row anatomy
/// (icon tile + title + secondary line), and a footer disclosure. The system
/// `confirmationDialog` the prior detail view used can't carry that visual
/// weight — the sheet replaces it.
///
/// ## Anatomy (plan §6.1)
///
/// - Grabber + `Cancel` (left) + `Rewrite` title + "N words · using <model>"
///   sub-line.
/// - One row per saved prompt. The default seeded prompt (the "Rewrite"
///   row at id `11111111-...`) renders with a coral `wand.and.stars` icon
///   + the "Default · polish without shortening" secondary copy from the
///   mockup. Additional user-created rows render with a purple
///   `list.bullet` icon by default — visually distinguishing user prompts
///   from the seeded default — and use a truncated systemPrompt preview
///   as the secondary line.
/// - "+ New prompt" footer row that dismisses the sheet and asks the host
///   to navigate the user to `AIRewriteSettingsView` (no inline creation).
/// - Disclosure footer: "Rewrite replaces the previous rewrite. Original
///   stays untouched." — verbatim from plan §6.1.
///
/// Sheet detent: `.height(360)` per plan §13 risk 6 — fixed-height drawer
/// keeps the layout stable across Dynamic Type sizes that would otherwise
/// blow past `.medium`.
struct RewritePickerSheet: View {

    /// Word count for the active transcript body, surfaced in the sub-line.
    let wordCount: Int

    /// Model display name to surface in the sub-line. Caller passes
    /// `JotDesign.activeRewriteModelDisplayName` so the sheet stays honest
    /// with the live provider.
    let modelDisplayName: String

    /// User's saved prompts, supplied by the host. Pre-sorted by
    /// `SavedPromptStore.all()` ordering.
    let prompts: [SavedPrompt]

    /// Fires when the user picks a prompt. Caller starts the in-process
    /// rewrite via `LLMClient.rewrite(...)`.
    let onPick: (SavedPrompt) -> Void

    /// Fires when the "Voice prompt" row's dictation finishes with non-empty
    /// text. The string is the user's *spoken instruction* ("make this shorter
    /// and turn it into an email to Sam") — the host wraps it into a rewrite
    /// system prompt and runs the SAME rewrite path `onPick` uses. The sheet
    /// dismisses itself before firing, mirroring `onPick`'s contract.
    let onVoicePrompt: (String) -> Void

    /// Fires when the user taps the "+ New prompt" affordance. Caller is
    /// expected to dismiss the sheet (already handled here via `dismiss()`)
    /// and route to `AIRewriteSettingsView`.
    let onNewPrompt: () -> Void

    /// Fires when the user taps the "Translate" row. The sheet dismisses itself
    /// first (mirroring `onPick`); the host presents the ephemeral Translate
    /// sheet (features.md §3.9) on the picker's dismissal so two sheets never
    /// race. NOT a `SavedPrompt` and NOT an LLM rewrite — it routes to Apple's
    /// on-device Translation, not `LLMClient.rewrite`.
    let onTranslate: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: Voice prompt state

    /// Process-wide recorder singleton, injected at the scene root by
    /// `JotApp`. Read here only for the voice row's "another recording is
    /// already live" disable state — the capture lifecycle itself goes
    /// through `VoicePromptCapture` (which talks to `.shared` directly).
    @Environment(RecordingService.self) private var recordingService

    /// Live partial-transcript presenter (same instance the hero and Ask
    /// read). `RecordingService.start()` mints a fresh streaming session per
    /// recording, so while our capture is live `streamingText` is OUR partial.
    @Environment(StreamingPartial.self) private var streamingPartial

    /// Which face the sheet is showing: the prompt list, the live voice
    /// capture, or the brief stop→transcribe tail.
    private enum VoicePhase {
        case idle          // prompt list
        case recording     // mic live, "Listening…"
        case transcribing  // gentle stop done, batch transcription running
    }

    @State private var voicePhase: VoicePhase = .idle

    /// Inline error line shown above the prompt list after a failed/empty
    /// voice capture ("Didn't catch that — try again.").
    @State private var voiceError: String?

    /// Lifecycle owner for the in-sheet capture. Created per attempt; nil'd
    /// after the terminal. `onDisappear` calls `stopGently()` on whatever is
    /// live so a drag-dismiss mid-recording never leaks a running mic.
    @State private var voiceCapture: VoicePromptCapture?

    /// Resizable detent (WS-G). The smallest stays `.height(360)` — the
    /// Dynamic-Type floor that keeps the header/subline/footer (which live
    /// OUTSIDE the inner ScrollView) from clipping on small devices — with
    /// two larger detents to drag up into.
    @State private var detent: PresentationDetent = .height(360)

    // Bundled default identification now flows through `SavedPrompt.defaultKind`
    // and the `RowKind` enum below — no per-id constants needed in this view.

    var body: some View {
        VStack(spacing: 0) {
            switch voicePhase {
            case .idle:
                pickerContent
            case .recording, .transcribing:
                voiceCaptureContent
            }
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WallpaperBackground())
        .presentationDetents([.height(360), .fraction(0.72), .large], selection: $detent)
        .presentationDragIndicator(.visible)
        // At the floor detent a content swipe resizes the sheet up; once
        // expanded it scrolls the prompt list (WS-G).
        .presentationContentInteraction(detent == .height(360) ? .resizes : .scrolls)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
        // During the brief stop→transcribe tail a drag-dismiss would tear the
        // sheet down while the rewrite hand-off is still in flight (the Stop
        // tap = explicit intent, so the rewrite WOULD still run — confusingly,
        // with no sheet left to show "Working…"). Cheapest coherent behavior:
        // pin the sheet for that stage. The X cancel is disabled there too.
        .interactiveDismissDisabled(voicePhase == .transcribing)
        .onDisappear {
            // Drag-dismiss (or any other teardown) mid-capture: stop the mic
            // GENTLY — the same warm-hold-honouring `stop()` every surface
            // uses. No-op when nothing is live (`isCapturing == false`,
            // e.g. after a Stop already finalized). The capture object holds
            // `RecordingService.shared` directly inside its teardown Task,
            // so the stop survives this view going away.
            voiceCapture?.stopGently()
        }
    }

    /// The default face: header + subline + saved-prompt list.
    private var pickerContent: some View {
        VStack(spacing: 0) {
            headerRow

            sublineRow
                .padding(.top, 6)
                .padding(.bottom, voiceError == nil ? 18 : 8)

            if let voiceError {
                Text(voiceError)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.jotWarning)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 8)
                    .accessibilityLabel(voiceError)
            }

            // Prompt rows scroll within the sheet so 4+ user prompts don't
            // overflow the fixed 360pt detent (plan §6.1). "+ New prompt"
            // stays pinned outside the ScrollView as a plain centered text
            // link. The "Voice prompt" row is pinned at position 2 — right
            // after the first saved prompt (the seeded default in practice).
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    if let first = prompts.first {
                        promptRow(first)
                    }
                    voicePromptRow
                    ForEach(prompts.dropFirst()) { prompt in
                        promptRow(prompt)
                    }
                    translateRow
                }
            }
            .scrollIndicators(.automatic)

            newPromptLink
                .padding(.top, 14)

            Spacer(minLength: 16)

            footerCopy
        }
    }

    // MARK: - Header / subline

    private var headerRow: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.jotMute)
            .accessibilityLabel("Cancel rewrite picker")

            Spacer()

            Text("Rewrite")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Spacer()

            // Symmetry spacer — matches the Cancel button's intrinsic
            // width so the title is visually centered without a layout
            // anchor on the sheet's parent.
            Text("Cancel")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 32)
    }

    private var sublineRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Text("\(wordCount) \(wordCount == 1 ? "word" : "words") · using \(modelDisplayName)")
                .font(.system(size: 12))
                .foregroundStyle(Color.jotMute)
                .monospacedDigit()
                .accessibilityLabel("\(wordCount) \(wordCount == 1 ? "word" : "words"), using \(modelDisplayName)")
            Spacer()
        }
    }

    // MARK: - Prompt rows

    @ViewBuilder
    private func promptRow(_ prompt: SavedPrompt) -> some View {
        let kind = rowKind(for: prompt)

        Button {
            onPick(prompt)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                IconBox(
                    symbol: kind.iconSymbol,
                    tint: kind.iconTint,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotInk)
                        .lineLimit(1)
                    Text(rowSecondary(for: prompt, kind: kind))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotMute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotMuteWeak)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .strokeBorder(Self.rowHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(prompt.name). \(rowSecondary(for: prompt, kind: kind))")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Voice prompt row (position 2)

    /// Dedicated "Voice prompt" row — NOT a `SavedPrompt`. Tapping it
    /// immediately starts an in-sheet recording; the user says what they want
    /// changed and the dictation becomes the rewrite instruction. Disabled
    /// while another recording (or a prior dictation's pipeline tail) is in
    /// flight so we never double-start the mic. Warm hold is a post-stop idle
    /// state (`isRecording == false`), so a warm-held mic does NOT disable
    /// the row.
    private var voicePromptRow: some View {
        let busy = recordingService.isRecording || recordingService.isPipelineInFlight
        return Button {
            beginVoiceCapture()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                IconBox(
                    symbol: "mic.fill",
                    tint: Color.jotCoralTop,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice prompt")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotInk)
                        .lineLimit(1)
                    Text("Say what to change.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotMute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotMuteWeak)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .strokeBorder(Self.rowHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .opacity(busy ? 0.45 : 1)
        .accessibilityLabel("Voice prompt. Say what to change.")
        .accessibilityHint("Starts recording immediately")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Translate row

    /// Dedicated "Translate" row — NOT a `SavedPrompt` and NOT an LLM rewrite.
    /// Tapping it dismisses the picker and asks the host to present the ephemeral
    /// Translate sheet (features.md §3.9), which runs Apple's on-device
    /// Translation. Placed last, after the saved prompts.
    private var translateRow: some View {
        Button {
            onTranslate()
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                IconBox(
                    symbol: "globe",
                    tint: JotDesign.JotSemanticIcon.vocabulary,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Translate")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotInk)
                        .lineLimit(1)
                    Text("To French, Spanish, and more.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotMute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotMuteWeak)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .strokeBorder(Self.rowHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Translate. To French, Spanish, and more.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Voice capture face

    /// Minimal in-sheet recording state: pulsing "Listening…" line, the live
    /// partial (when the streaming model has produced one), a prominent Stop,
    /// and an X that gently stops and returns to the list without rewriting.
    private var voiceCaptureContent: some View {
        VStack(spacing: 0) {
            // Header: X (cancel) left, title centered via symmetry spacer.
            HStack {
                Button {
                    cancelVoiceCapture()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.jotMute)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(voicePhase == .transcribing)
                .accessibilityLabel("Cancel voice prompt")

                Spacer()

                Text("Voice prompt")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.jotInk)

                Spacer()

                // Symmetry spacer matching the X button's footprint.
                Color.clear
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 32)

            HStack(spacing: 8) {
                VoicePromptPulsingDot()
                Text(voicePhase == .transcribing ? "Working…" : "Listening…")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.jotInk)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Live partial from the process-wide streaming presenter. Our
            // `start()` minted a fresh streaming session, so this is this
            // capture's text. Render only while the mic is live — during the
            // stop tail the batch model owns the final say.
            ScrollView(.vertical, showsIndicators: false) {
                if voicePhase == .recording, !streamingPartial.streamingText.isEmpty {
                    Text(streamingPartial.streamingText)
                        .font(.system(size: 14))
                        .foregroundStyle(Color.jotMute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity)

            if voicePhase == .transcribing {
                ProgressView()
                    .padding(.vertical, 15)
            } else {
                Button {
                    finishVoiceCapture()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Stop")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.jotCoralTop)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop recording and run rewrite")
            }
        }
    }

    // MARK: - Voice capture actions

    /// Row tap → start recording IMMEDIATELY. Guarded against double-start:
    /// if another recording or pipeline tail is somehow live (the row is
    /// disabled, but a race is cheap to close), this no-ops gracefully.
    private func beginVoiceCapture() {
        guard !recordingService.isRecording, !recordingService.isPipelineInFlight else { return }
        guard voiceCapture == nil else { return }
        voiceError = nil
        let capture = VoicePromptCapture(streamingPartial: streamingPartial)
        voiceCapture = capture
        voicePhase = .recording
        Task {
            let started = await capture.start()
            if !started {
                // Mic bring-up failed (permission, session conflict). Return
                // to the list with the inline error line.
                voiceCapture = nil
                voicePhase = .idle
                voiceError = "Couldn't start recording — try again."
            }
        }
    }

    /// Stop → transcribe → hand the instruction to the host and dismiss.
    /// Empty/failed transcription returns to the list with an inline error.
    private func finishVoiceCapture() {
        guard voicePhase == .recording, let capture = voiceCapture else { return }
        voicePhase = .transcribing
        Task {
            let text = await capture.finish()
            voiceCapture = nil
            if let text {
                onVoicePrompt(text)
                dismiss()
            } else {
                voicePhase = .idle
                voiceError = "Didn't catch that — try again."
            }
        }
    }

    /// X tap → gentle stop (warm hold honoured), drop the audio, return to
    /// the picker list. No rewrite runs.
    private func cancelVoiceCapture() {
        voiceCapture?.stopGently()
        voiceCapture = nil
        voicePhase = .idle
        voiceError = nil
    }

    /// Adaptive hairline shared by the prompt-row cards.
    /// Subtle dark stroke in light mode, subtle light stroke in dark mode —
    /// reads as a rim on either material fill.
    private static let rowHairline = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.10)
            : UIColor(white: 0.0, alpha: 0.06)
    })

    /// One of five visual kinds for a picker row, keyed by the stable id of
    /// the seeded defaults. User-created rows fall through to `.userPrompt`
    /// which renders with the purple list glyph.
    private enum RowKind {
        case articulate
        case aiPrompt
        case actionItems
        case email
        case userPrompt

        var iconSymbol: String {
            switch self {
            case .articulate:  return "wand.and.stars"
            case .aiPrompt:    return "text.bubble"
            case .actionItems: return "checklist"
            case .email:       return "envelope"
            case .userPrompt:  return "list.bullet"
            }
        }

        var iconTint: Color {
            switch self {
            case .articulate:  return Color.jotCoralTop
            case .aiPrompt:    return Color.jotPromptTeal
            case .actionItems: return Color.jotPromptPurple
            case .email:       return Color.jotSuccess
            case .userPrompt:  return Color.jotPromptPurple
            }
        }
    }

    private func rowKind(for prompt: SavedPrompt) -> RowKind {
        switch prompt.defaultKind {
        case .articulate:  return .articulate
        case .aiPrompt:    return .aiPrompt
        case .actionItems: return .actionItems
        case .email:       return .email
        case nil:          return .userPrompt
        }
    }

    /// Secondary copy under the prompt name. Seeded defaults carry canon
    /// one-liners; user-created prompts surface a single-line preview of their
    /// saved system prompt so the picker is self-describing.
    private func rowSecondary(for prompt: SavedPrompt, kind: RowKind) -> String {
        switch kind {
        case .articulate:
            return "Default · polish dictation, keep voice"
        case .aiPrompt:
            return "Default · structure for Claude or ChatGPT"
        case .actionItems:
            return "Default · extract tasks and deadlines"
        case .email:
            return "Default · business email with subject"
        case .userPrompt:
            let cleaned = prompt.systemPrompt
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? "Custom prompt" : cleaned
        }
    }

    private var newPromptLink: some View {
        Button {
            onNewPrompt()
            dismiss()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                Text("New prompt")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Color.jotCoralTop)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New prompt")
        .accessibilityHint("Opens AI Rewrite settings to create a new prompt")
    }

    // MARK: - Footer

    private var footerCopy: some View {
        Text("Rewrite replaces the previous rewrite. Original stays untouched.")
            .font(.system(size: 12))
            .foregroundStyle(Color.jotMute)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .accessibilityLabel("Rewrite replaces the previous rewrite. Original stays untouched.")
    }
}

// MARK: - Voice prompt capture lifecycle

/// Start → gentle-stop → batch-transcribe lifecycle for the picker's
/// "Voice prompt" row. The dictated text becomes a rewrite *instruction* —
/// it is never saved as a `Transcript`, never published to the clipboard,
/// never pasted into any field, and never routed through
/// `DictationPipeline` (so no stats, no follow-up classification, no
/// keyboard auto-paste session).
///
/// ## Seam
///
/// Talks to the raw primitives directly — `RecordingService.shared.start()`
/// / `.stop()` (the gentle, warm-hold-honouring stop) and
/// `TranscriptionService.shared.transcribe(samples:)` — the same public seam
/// `DictationControllerImpl` and the in-Jot keyboard capture use.
/// `InlineDictationSession` is deliberately NOT used: Ask is its sole
/// permitted caller (see that file's header). This type replicates the same
/// four fragile invariants its docs spell out:
///
///   1. `await` the in-flight `start()` before any terminal — cancelling it
///      mid-bring-up races the engine and leaks a live recording.
///   2. call `markPipelineFinished()` by hand after `stop()` — this path
///      bypasses the normal post-stop pipeline, so the in-flight latch is
///      never released otherwise.
///   3. publish a terminal `.idle` phase — `stop()` published
///      `.transcribing` cross-process and nothing downstream of us will
///      advance it (no pending-paste session exists, so the write is
///      side-effect-free beyond resetting the keyboard's CTA).
///   4. NEVER `forceStop()` — both terminals use the gentle `stop()` so
///      Warm Hold is honoured exactly as every other surface does.
///
/// `ownsActiveRecording` is CLAIMED (`true`) before `start()` and cleared on
/// EVERY terminal — mirroring `InlineDictationSession` exactly. Per the
/// adversarial review (R2), the flag is the GENERIC "an in-app surface owns
/// this recording" signal — the "Ask is the sole user" rule applies to the
/// `InlineDictationSession` TYPE, not to this flag. Every coordinator reads
/// it generically, and each read is load-bearing for this capture:
///
///   - `JotApp.handleStopRequested` bails on it — without the claim, a
///     keyboard mic-tap from ANOTHER APP while we record would fall through
///     to the save+publish pipeline (transient=false in the background) and
///     SAVE the spoken instruction as a transcript + auto-paste it there.
///   - `RecordingService.stop()`'s `isInlineStop` snapshot excludes owned
///     stops from the warm-hold-nudge ring — without it, quick voice-prompt
///     retries would manufacture a false switching-nudge streak.
///   - `RecordingService.internalStop` drops the interruption publish for
///     owned captures (no save / no clipboard on an incoming call).
///   - `ContentView.isLiveRecordingInline` suppresses the return pill.
///
/// `markPipelineFinished()` backstops the clear at every pipeline terminal,
/// exactly as it does for Ask.
///
/// Vocabulary provenance: `transcribe(samples:)` runs the rescore and
/// stashes pending correction proposals, but `clearPending()` fires at the
/// start of EVERY batch transcription and proposals only persist via the
/// save-path `commit(transcriptID:)` — which never runs here. So this
/// capture's proposals can never leak into the next real dictation's commit.
@MainActor
@Observable
final class VoicePromptCapture {
    /// True between a successful `start()` kickoff and a terminal.
    private(set) var isCapturing = false

    /// In-flight `start()` bring-up, awaited before any terminal (invariant 1).
    private var startTask: Task<Bool, Never>?

    /// The process-wide live-partial presenter (the same instance `JotApp`
    /// injects into the environment AND into `RecordingService`). Reset on
    /// every terminal so the final instruction text doesn't linger in the
    /// App-Group projection (keyboard streaming strip) after the capture
    /// ends — the batch-override `reset()` that normally clears it lives in
    /// the hero flow, which this capture bypasses.
    private let streamingPartial: StreamingPartial

    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "rewrite-voice-prompt"
    )

    init(streamingPartial: StreamingPartial) {
        self.streamingPartial = streamingPartial
    }

    /// Begin the capture. Returns `false` (and resets) if the recorder is
    /// busy or mic bring-up failed.
    func start() async -> Bool {
        let recording = RecordingService.shared
        guard !isCapturing, !recording.isRecording, !recording.isPipelineInFlight else {
            log.notice("voice-prompt start skipped — recorder busy")
            return false
        }
        isCapturing = true
        log.notice("RECORDING START FROM: RewritePickerSheet (voice prompt)")
        // Claim ownership BEFORE start() — see the type doc: this is the
        // generic "an in-app surface owns this recording" signal (adversarial
        // review R2), the same claim Ask makes. It keeps the cross-process
        // keyboard stop from routing our instruction into the save+auto-paste
        // pipeline, keeps owned stops out of the warm-hold-nudge ring, drops
        // the interruption publish, and suppresses home's return pill.
        recording.ownsActiveRecording = true
        let task = Task { @MainActor () -> Bool in
            do {
                try await recording.start()
                return true
            } catch {
                self.log.error("voice-prompt start failed: \(error.localizedDescription, privacy: .public)")
                return false
            }
        }
        startTask = task
        let started = await task.value
        if !started {
            isCapturing = false
            startTask = nil
            recording.ownsActiveRecording = false // terminal: failed bring-up
        }
        return started
    }

    /// Gentle stop → batch transcription. Returns the trimmed instruction
    /// text, or `nil` if nothing was captured / transcription failed or came
    /// back empty.
    func finish() async -> String? {
        guard isCapturing else { return nil }
        isCapturing = false
        let pending = startTask
        startTask = nil
        _ = await pending?.value // invariant 1
        let recording = RecordingService.shared
        do {
            let samples = try await recording.stop() // gentle; Warm Hold honoured
            recording.markPipelineFinished()         // invariant 2
            recording.ownsActiveRecording = false    // terminal: release ownership
            recording.publishPipelinePhase(.idle)    // invariant 3
            // stop() already promoted + published the final streaming snapshot
            // (tearDownStreamingSession runs inside it) — clear the preview so
            // the instruction doesn't linger in the keyboard's strip.
            streamingPartial.reset()
            let text = try await TranscriptionService.shared.transcribe(samples: samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            // stop() threw (its catch already released the latch) or
            // transcription threw — release defensively either way so the
            // recorder is never wedged for the next dictation.
            recording.markPipelineFinished()
            recording.ownsActiveRecording = false    // terminal: release ownership
            recording.publishPipelinePhase(.idle)
            streamingPartial.reset()
            log.error("voice-prompt finish failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Gentle stop WITHOUT transcribing — the cancel/dismiss path. The audio
    /// is dropped. Captures `RecordingService.shared` (and the presenter) in
    /// locals so the teardown Task holds them directly — NOT `self` weakly —
    /// and therefore survives the sheet (and this object's owner) going away
    /// mid-`await`.
    func stopGently() {
        let pending = startTask
        startTask = nil
        guard isCapturing else {
            // Nothing live, but ownership must never be left stuck (mirrors
            // InlineDictationSession.stopGently's early-return clear).
            RecordingService.shared.ownsActiveRecording = false
            return
        }
        isCapturing = false
        let recording = RecordingService.shared
        let presenter = streamingPartial
        let log = log
        Task {
            _ = await pending?.value // invariant 1
            do {
                _ = try await recording.stop() // gentle; Warm Hold honoured
            } catch {
                // stop() released its own in-flight latch on throw.
                log.error("voice-prompt gentle stop failed: \(error.localizedDescription, privacy: .public)")
            }
            recording.markPipelineFinished()      // invariant 2
            recording.ownsActiveRecording = false // terminal: release ownership
            recording.publishPipelinePhase(.idle) // invariant 3
            presenter.reset()
        }
    }
}

/// Simple pulsing recording indicator for the voice-capture face — a coral
/// dot breathing on a 0.8s cycle. Deliberately not a waveform (cheapest
/// pattern that reads as "live mic").
private struct VoicePromptPulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.jotCoralTop)
            .frame(width: 10, height: 10)
            .scaleEffect(pulsing ? 1.0 : 0.6)
            .opacity(pulsing ? 1.0 : 0.5)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
            .accessibilityHidden(true)
    }
}

// MARK: - Prompt-purple accent

extension Color {
    /// Purple icon used for the "Bullet points" / user-prompt rows in the
    /// rewrite picker (Mockup 10). Distinct from `jotCoralTop` (coral) so the
    /// seeded default row reads as the visually primary option. Not part of
    /// Phase 1 tokens because nothing else in the system uses it yet;
    /// scoped to this file so the design system stays single-accent.
    fileprivate static let jotPromptPurple = Color(red: 0.55, green: 0.40, blue: 0.90)

    /// Teal tile for the bundled "AI prompt" default. Matches
    /// `AIV09Tokens.teal` in `AIRewriteSettingsView`. Kept here too
    /// because RewritePickerSheet doesn't import the AIV09 namespace.
    fileprivate static let jotPromptTeal = Color(red: 0x33 / 255, green: 0xB5 / 255, blue: 0xA8 / 255)
}

#Preview {
    Color.gray
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            RewritePickerSheet(
                wordCount: 52,
                modelDisplayName: "Qwen 3.5 4B",
                prompts: [SavedPrompt.defaultArticulate],
                onPick: { _ in },
                onVoicePrompt: { _ in },
                onNewPrompt: {},
                onTranslate: {}
            )
            .environment(RecordingService.shared)
            .environment(StreamingPartial())
        }
}
