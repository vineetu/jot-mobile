@preconcurrency import AVFoundation
import Foundation
import SwiftUI

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

    /// Fires when the user taps the "+ New prompt" affordance. Caller is
    /// expected to dismiss the sheet (already handled here via `dismiss()`)
    /// and route to `AIRewriteSettingsView`.
    let onNewPrompt: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showVoicePrompt: Bool = false

    /// Stable id of the bundled default rewrite prompt — used to pick
    /// the coral wand glyph for the seeded row.
    private static let defaultRewriteID = SavedPrompt.defaultRewrite.id

    /// Stable id of the bundled bullet-points prompt — used to pick
    /// the purple `list.bullet` glyph + canon mockup copy. User-created
    /// prompts also default to the purple list glyph; the id-based branch
    /// only changes the secondary-line copy.
    private static let defaultBulletPointsID = SavedPrompt.defaultBulletPoints.id

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            sublineRow
                .padding(.top, 6)
                .padding(.bottom, 18)

            // Prompt rows scroll within the sheet so 4+ user prompts don't
            // overflow the fixed 360pt detent (plan §6.1). Voice prompt
            // sits at the tail of the same list as a compact one-line row
            // so it reads as "one more prompt option" instead of standing
            // off in a separate footer card. "+ New prompt" stays pinned
            // outside the ScrollView as a plain centered text link.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    ForEach(prompts) { prompt in
                        promptRow(prompt)
                    }
                    voicePromptRow
                }
            }
            .scrollIndicators(.automatic)

            newPromptLink
                .padding(.top, 14)

            Spacer(minLength: 16)

            footerCopy
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WallpaperBackground())
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
        .sheet(isPresented: $showVoicePrompt) {
            VoicePromptCaptureView(
                onTranscribed: { synthetic in
                    showVoicePrompt = false
                    onPick(synthetic)
                    dismiss()
                },
                onCancel: {
                    showVoicePrompt = false
                }
            )
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

    /// Adaptive hairline shared by the prompt-row and voice-prompt-row cards.
    /// Subtle dark stroke in light mode, subtle light stroke in dark mode —
    /// reads as a rim on either material fill.
    private static let rowHairline = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.10)
            : UIColor(white: 0.0, alpha: 0.06)
    })

    /// One of three visual kinds for a picker row, keyed by the stable id of
    /// the seeded defaults. User-created rows fall through to `.userPrompt`
    /// which renders with the purple list glyph — same as the seeded
    /// bullet-points row — so the picker stays visually unified for
    /// list-style prompts while singling out the coral "Rewrite" default.
    private enum RowKind {
        case defaultRewrite
        case defaultBulletPoints
        case userPrompt

        var iconSymbol: String {
            switch self {
            case .defaultRewrite: return "wand.and.stars"
            case .defaultBulletPoints, .userPrompt: return "list.bullet"
            }
        }

        var iconTint: Color {
            switch self {
            case .defaultRewrite: return Color.jotAccent
            case .defaultBulletPoints, .userPrompt: return Color.jotPromptPurple
            }
        }
    }

    private func rowKind(for prompt: SavedPrompt) -> RowKind {
        if prompt.id == Self.defaultRewriteID { return .defaultRewrite }
        if prompt.id == Self.defaultBulletPointsID { return .defaultBulletPoints }
        return .userPrompt
    }

    /// Secondary copy under the prompt name. Seeded defaults carry mockup-canon
    /// strings; user-created prompts surface a single-line preview of their
    /// saved system prompt so the picker is self-describing.
    private func rowSecondary(for prompt: SavedPrompt, kind: RowKind) -> String {
        switch kind {
        case .defaultRewrite:
            return "Default · polish without shortening"
        case .defaultBulletPoints:
            return "Default · one idea per bullet"
        case .userPrompt:
            let cleaned = prompt.systemPrompt
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? "Custom prompt" : cleaned
        }
    }

    private var voicePromptRow: some View {
        Button {
            showVoicePrompt = true
        } label: {
            HStack(alignment: .center, spacing: 12) {
                IconBox(
                    symbol: "mic.fill",
                    tint: Color.jotAccent,
                    size: 32
                )

                Text("Voice prompt — dictate a one-shot instruction")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.jotMuteWeak)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
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
        .accessibilityLabel("Voice prompt. Dictate a one-shot rewrite instruction.")
        .accessibilityAddTraits(.isButton)
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
            .foregroundStyle(Color.jotAccent)
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

// MARK: - Voice prompt capture

@MainActor
private struct VoicePromptCaptureView: View {
    let onTranscribed: (SavedPrompt) -> Void
    let onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var engine = VoicePromptCaptureEngine()
    @State private var captureState: CaptureState = .idle
    @State private var elapsedSeconds: Int = 0
    @State private var elapsedTask: Task<Void, Never>?
    @State private var transcriptionTask: Task<Void, Never>?
    @State private var currentTranscriptionDiscardFlag: DiscardResultFlag?
    @State private var didAutoStart: Bool = false

    private static let maxRecordingSeconds: Int = 60

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            Spacer(minLength: 24)

            captureContent
                .frame(maxWidth: .infinity)

            Spacer(minLength: 24)
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WallpaperBackground())
        .presentationDetents([.height(320)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
        .onAppear {
            configureEngineCallbacks()
            autoStartIfNeeded()
        }
        .onDisappear {
            teardownCapture()
        }
    }

    private var headerRow: some View {
        HStack {
            Button("Cancel") {
                cancel()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.jotMute)
            .accessibilityLabel("Cancel voice prompt")

            Spacer()

            Text("Voice prompt")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Spacer()

            Text("Cancel")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private var captureContent: some View {
        switch captureState {
        case .idle, .recording:
            VStack(spacing: 14) {
                Button {
                    toggleRecording()
                } label: {
                    Image(systemName: captureButtonSymbol)
                        .font(.system(size: 80, weight: .regular))
                        .foregroundStyle(Color.jotAccent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(captureButtonAccessibilityLabel)

                Text(formattedElapsed)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.jotInk)
                    .monospacedDigit()
            }

        case .transcribing:
            VStack(spacing: 14) {
                Button {} label: {
                    Image(systemName: "mic.circle.fill")
                        .font(.system(size: 80, weight: .regular))
                        .foregroundStyle(Color.jotMuteWeak)
                }
                .buttonStyle(.plain)
                .disabled(true)
                .accessibilityLabel("Transcribing voice prompt")

                ProgressView()

                Text("Transcribing...")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.jotMute)
            }

        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 52, weight: .regular))
                    .foregroundStyle(Color.jotAccent)

                Text(message)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.jotInk)
                    .multilineTextAlignment(.center)

                Button("Try again") {
                    resetToIdle()
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotAccent)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var captureButtonSymbol: String {
        switch captureState {
        case .recording:
            return "stop.circle.fill"
        case .idle, .transcribing, .error:
            return "mic.circle.fill"
        }
    }

    private var captureButtonAccessibilityLabel: String {
        switch captureState {
        case .recording:
            return "Stop recording"
        case .idle, .transcribing, .error:
            return "Start recording voice prompt"
        }
    }

    private var formattedElapsed: String {
        let clamped = min(elapsedSeconds, Self.maxRecordingSeconds)
        let minutes = clamped / 60
        let seconds = clamped % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func configureEngineCallbacks() {
        engine.onAutoStopped = { samples in
            stopElapsedTimer()
            elapsedSeconds = Self.maxRecordingSeconds
            runTranscription(samples: samples)
        }

        engine.onInterrupted = {
            stopElapsedTimer()
            captureState = .error("Recording interrupted. Try again.")
        }
    }

    private func autoStartIfNeeded() {
        guard didAutoStart == false else { return }
        didAutoStart = true
        // Only auto-start once the user has already granted mic access.
        // Manual taps handle prompting or denied-permission guidance.
        guard AVAudioApplication.shared.recordPermission == .granted else { return }
        startRecording()
    }

    private func toggleRecording() {
        switch captureState {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .transcribing, .error:
            break
        }
    }

    private func startRecording() {
        captureState = .recording
        elapsedSeconds = 0
        startElapsedTimer()

        Task {
            do {
                try await engine.start()
            } catch {
                stopElapsedTimer()
                elapsedSeconds = 0
                captureState = .error(startErrorMessage(for: error))
            }
        }
    }

    private func stopRecording() {
        stopElapsedTimer()
        captureState = .transcribing

        Task {
            let samples = await engine.stop()
            runTranscription(samples: samples)
        }
    }

    private func runTranscription(samples: [Float]) {
        transcriptionTask?.cancel()
        currentTranscriptionDiscardFlag?.value = true
        captureState = .transcribing

        // Cooperative cancellation flag: TranscriptionService.transcribe(samples:)
        // can keep computing after Task.cancel() until the underlying manager
        // returns. This flag lets the Task closure drop the result without
        // surfacing it or invoking onTranscribed, even if cancellation arrives
        // mid-await between the transcribe return and the dispatch site below.
        let discardResult = DiscardResultFlag()
        currentTranscriptionDiscardFlag = discardResult

        transcriptionTask = Task {
            do {
                let transcript = try await TranscriptionService.shared.transcribe(samples: samples)
                let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !Task.isCancelled, !discardResult.value else {
                    transcriptionTask = nil
                    return
                }

                guard !trimmed.isEmpty else {
                    captureState = .error("No speech detected. Try again.")
                    transcriptionTask = nil
                    return
                }

                let synthetic = SavedPrompt(
                    id: UUID(),
                    name: "Voice prompt",
                    systemPrompt: trimmed,
                    createdAt: Date(),
                    sortOrder: 0
                )
                transcriptionTask = nil
                guard !discardResult.value else { return }
                onTranscribed(synthetic)
                dismiss()
            } catch is CancellationError {
                transcriptionTask = nil
            } catch {
                guard !Task.isCancelled, !discardResult.value else {
                    transcriptionTask = nil
                    return
                }
                captureState = .error(transcriptionErrorMessage(for: error))
                transcriptionTask = nil
            }
        }
    }

    private func cancel() {
        teardownCapture()
        onCancel()
        dismiss()
    }

    private func resetToIdle() {
        stopElapsedTimer()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentTranscriptionDiscardFlag?.value = true
        currentTranscriptionDiscardFlag = nil
        elapsedSeconds = 0
        captureState = .idle
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        let startedAt = Date()

        elapsedTask = Task { @MainActor in
            while !Task.isCancelled {
                elapsedSeconds = min(Self.maxRecordingSeconds, Int(Date().timeIntervalSince(startedAt)))

                guard elapsedSeconds < Self.maxRecordingSeconds else { break }
                guard case .recording = captureState else { break }

                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    break
                }
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = nil
    }

    private func teardownCapture() {
        stopElapsedTimer()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        currentTranscriptionDiscardFlag?.value = true
        currentTranscriptionDiscardFlag = nil
        engine.onAutoStopped = nil
        engine.onInterrupted = nil

        Task {
            _ = await engine.stop()
        }
    }

    private func startErrorMessage(for error: Error) -> String {
        if let captureError = error as? VoicePromptCaptureEngine.CaptureError {
            return captureError.errorDescription ?? "Microphone permission required."
        }

        return "Microphone permission required."
    }

    private func transcriptionErrorMessage(for error: Error) -> String {
        if let transcriptionError = error as? TranscriptionService.TranscriptionError,
           case .audioTooShort = transcriptionError {
            return "No speech detected. Try again."
        }

        if let localized = (error as? LocalizedError)?.errorDescription {
            return localized
        }

        return "Transcription failed. Try again."
    }

    private enum CaptureState: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }
}

/// Reference-typed cooperative-cancellation flag for the voice-prompt
/// transcription Task. Accessed only on `MainActor` — the `runTranscription`
/// Task closure inherits the enclosing View's MainActor isolation, and every
/// cancel/teardown path also runs on MainActor. Carries the discard signal
/// across the `await TranscriptionService.transcribe(samples:)` boundary
/// even after `Task.cancel()` has been called.
@MainActor
private final class DiscardResultFlag {
    var value: Bool = false
}

@MainActor
private final class VoicePromptCaptureEngine {
    enum CaptureError: LocalizedError {
        case alreadyRecording
        case dictationActive
        case converterUnavailable
        case sessionConfiguration(Error)
        case microphonePermissionRequired

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "A recording is already in progress."
            case .dictationActive:
                return "Stop your current dictation first."
            case .converterUnavailable:
                return "Could not build the 16 kHz audio converter."
            case .sessionConfiguration(let error):
                return "Audio session error: \(error.localizedDescription)"
            case .microphonePermissionRequired:
                return "Microphone permission required."
            }
        }
    }

    var onAutoStopped: (([Float]) -> Void)?
    var onInterrupted: (() -> Void)?

    private var engine: AVAudioEngine?
    private var sampleBuffer: VoicePromptSampleBuffer?
    private var isRecording: Bool = false
    private var autoStopTask: Task<Void, Never>?
    private var interruptionObserver: NSObjectProtocol?
    private var priorCategory: AVAudioSession.Category?
    private var priorMode: AVAudioSession.Mode?
    private var priorOptions: AVAudioSession.CategoryOptions?

    private static let maxRecordingNanoseconds: UInt64 = 60_000_000_000

    func start() async throws {
        guard !RecordingService.shared.isRecording, !RecordingService.shared.isWarm else {
            throw CaptureError.dictationActive
        }
        guard !isRecording else { throw CaptureError.alreadyRecording }

        try configureSession()

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardwareFormat = input.outputFormat(forBus: 0)

        guard let converter = AVAudioConverter(from: hardwareFormat, to: RecordingService.target) else {
            restoreSession()
            throw CaptureError.converterUnavailable
        }

        let sampleBuffer = VoicePromptSampleBuffer(
            converter: converter,
            inputFormat: hardwareFormat,
            target: RecordingService.target
        )

        installTap(on: engine, hardwareFormat: hardwareFormat, sampleBuffer: sampleBuffer)

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            restoreSession()
            throw CaptureError.microphonePermissionRequired
        }

        self.engine = engine
        self.sampleBuffer = sampleBuffer
        isRecording = true
        subscribeInterruptionObserver()

        autoStopTask?.cancel()
        autoStopTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.maxRecordingNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            await self?.handleAutoStop()
        }
    }

    func stop() async -> [Float] {
        stopCurrentRecording(cancelAutoStop: true)
    }

    private func installTap(
        on engine: AVAudioEngine,
        hardwareFormat: AVAudioFormat,
        sampleBuffer: VoicePromptSampleBuffer
    ) {
        let input = engine.inputNode
        let tapBlock: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { [sampleBuffer] pcm, _ in
            sampleBuffer.appendConverted(pcm)
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: hardwareFormat, block: tapBlock)
    }

    private func handleAutoStop() {
        guard isRecording else { return }
        let samples = stopCurrentRecording(cancelAutoStop: false)
        onAutoStopped?(samples)
    }

    private func stopCurrentRecording(cancelAutoStop: Bool) -> [Float] {
        guard isRecording || engine != nil || sampleBuffer != nil || priorCategory != nil else {
            if cancelAutoStop {
                autoStopTask?.cancel()
            }
            autoStopTask = nil
            return []
        }

        if cancelAutoStop {
            autoStopTask?.cancel()
        }
        autoStopTask = nil

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        let samples = sampleBuffer?.drain() ?? []
        sampleBuffer = nil
        engine = nil
        isRecording = false
        unsubscribeInterruptionObserver()
        restoreSession()
        return samples
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        priorCategory = session.category
        priorMode = session.mode
        priorOptions = session.categoryOptions

        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            restoreSession()
            throw CaptureError.sessionConfiguration(error)
        }
    }

    private func restoreSession() {
        let session = AVAudioSession.sharedInstance()

        try? session.setActive(false, options: [.notifyOthersOnDeactivation])

        if let priorCategory, let priorMode, let priorOptions {
            try? session.setCategory(priorCategory, mode: priorMode, options: priorOptions)
        }

        priorCategory = nil
        priorMode = nil
        priorOptions = nil
    }

    private func subscribeInterruptionObserver() {
        guard interruptionObserver == nil else { return }

        let session = AVAudioSession.sharedInstance()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let typeRaw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeRaw: typeRaw)
            }
        }
    }

    private func unsubscribeInterruptionObserver() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
    }

    private func handleInterruption(typeRaw: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }

        if type == .began {
            _ = stopCurrentRecording(cancelAutoStop: true)
            onInterrupted?()
        }
    }
}

private final class VoicePromptSampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let target: AVAudioFormat
    private var samples: [Float] = []
    private var isDrained: Bool = false

    init(converter: AVAudioConverter, inputFormat: AVAudioFormat, target: AVAudioFormat) {
        self.converter = converter
        self.inputFormat = inputFormat
        self.target = target
    }

    func appendConverted(_ pcm: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }

        guard !isDrained, pcm.format == inputFormat else { return }

        let ratio = target.sampleRate / pcm.format.sampleRate
        let estimatedFrames = AVAudioFrameCount(Double(pcm.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: estimatedFrames) else { return }

        let gate = VoicePromptInputGate()
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if gate.take() {
                inputStatus.pointee = .haveData
                return pcm
            }

            inputStatus.pointee = .noDataNow
            return nil
        }

        switch status {
        case .error:
            return
        case .haveData, .inputRanDry, .endOfStream:
            break
        @unknown default:
            return
        }

        guard let channelData = outputBuffer.floatChannelData else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        isDrained = true
        let drained = samples
        samples = []
        return drained
    }
}

private final class VoicePromptInputGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didSupplyInput = false

    func take() -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard !didSupplyInput else { return false }
        didSupplyInput = true
        return true
    }
}

// MARK: - Prompt-purple accent

extension Color {
    /// Purple icon used for the "Bullet points" / user-prompt rows in the
    /// rewrite picker (Mockup 10). Distinct from `jotAccent` (coral) so the
    /// seeded default row reads as the visually primary option. Not part of
    /// Phase 1 tokens because nothing else in the system uses it yet;
    /// scoped to this file so the design system stays single-accent.
    fileprivate static let jotPromptPurple = Color(red: 0.55, green: 0.40, blue: 0.90)
}

#Preview {
    Color.gray
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            RewritePickerSheet(
                wordCount: 52,
                modelDisplayName: "Qwen 3.5 4B",
                prompts: [SavedPrompt.defaultRewrite],
                onPick: { _ in },
                onNewPrompt: {}
            )
        }
}
