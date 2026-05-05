import SwiftData
import SwiftUI
import UIKit
import os.log

private let contentLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "content")

struct ContentView: View {
    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingPartial.self) private var streamingPartial
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @Query(sort: \Transcript.createdAt, order: .reverse)
    private var transcripts: [Transcript]

    @State private var phase: RecordingPhase = .idle
    @State private var searchText = ""
    @State private var showSettings = false
    @State private var pendingDeletion: Transcript?
    @State private var activeTask: Task<Void, Never>?
    @State private var startedAt: Date?
    @State private var elapsed: TimeInterval = 0
    @State private var vuTimer: Timer?
    @State private var vuBars: [CGFloat] = Array(repeating: 0.14, count: 16)
    @State private var errorMessage: String?
    @State private var copiedTranscriptID: UUID?
    @State private var copyResetTask: Task<Void, Never>?
    @State private var startHaptic = UIImpactFeedbackGenerator(style: .medium)
    @State private var stopHaptic = UIImpactFeedbackGenerator(style: .soft)
    @State private var copyHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var successHaptic = UINotificationFeedbackGenerator()

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }

                if filteredTranscripts.isEmpty {
                    ContentUnavailableView(
                        searchText.isEmpty ? "No transcripts yet" : "No matching transcripts",
                        systemImage: "mic",
                        description: Text(searchText.isEmpty ? "Tap to dictate." : "Try a different search.")
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(filteredTranscripts) { transcript in
                        NavigationLink {
                            TranscriptDetailView(transcript: transcript)
                        } label: {
                            TranscriptRow(
                                transcript: transcript,
                                isCopied: copiedTranscriptID == transcript.id
                            )
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            // Copy listed first → revealed first on a small swipe.
                            // Delete is the destructive secondary action behind it.
                            Button {
                                copy(transcript)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                            .tint(.accentColor)

                            Button(role: .destructive) {
                                pendingDeletion = transcript
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        .onLongPressGesture(minimumDuration: 0.4) {
                            copy(transcript)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Jot")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    streamingPreviewView
                    RecorderBar(
                        phase: phase,
                        elapsed: elapsed,
                        vuBars: vuBars,
                        caption: recorderCaption,
                        action: toggleRecording
                    )
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                }
                .background(.bar)
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { transcript in
            Button("Delete", role: .destructive) {
                delete(transcript)
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        }
        .onAppear {
            startHaptic.prepare()
            stopHaptic.prepare()
            copyHaptic.prepare()
            successHaptic.prepare()
            syncRecordingState()
        }
        .onChange(of: recordingService.isRecording) { _, _ in
            syncRecordingState()
        }
        .onDisappear {
            stopVUTimer()
            activeTask?.cancel()
            copyResetTask?.cancel()
        }
    }

    private var filteredTranscripts: [Transcript] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return transcripts }

        return transcripts.filter { transcript in
            transcript.text.localizedCaseInsensitiveContains(query)
                || (transcript.cleanedText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var recorderCaption: String {
        switch phase {
        case .idle:
            return transcripts.isEmpty ? "Tap to dictate" : "Tap to dictate again"
        case .recording:
            return "Listening... tap to stop"
        case .transcribing:
            switch transcriptionService.modelState {
            case .ready:
                return "Transcribing..."
            case .downloading:
                return "Downloading speech model..."
            case .loading, .notLoaded:
                return "Preparing speech model..."
            case .failed:
                return "Speech model needs attention"
            }
        }
    }

    /// Live partial-transcript preview (dual-model-streaming).
    ///
    /// Renders the FluidAudio EOU streaming model's cumulative partial only
    /// while a recording is in flight (`.recording`) or its tail is in
    /// transcribe mode (`.transcribing`). Volatile partials render with
    /// `.secondary` foreground; once `engine.finish()` runs and the
    /// presenter's `applyFinalSnapshot` flips `streamingIsVolatile = false`,
    /// foreground promotes to `.primary` for the brief pre-batch tail
    /// before the batch transcript blanks the field via
    /// `streamingPartial.reset()`.
    ///
    /// - Hidden when `streamingText.isEmpty` so the spacer doesn't appear
    ///   before the model's first emission.
    /// - `.lineLimit(3)` caps growth; long recordings show only the most
    ///   recent prefix the EOU model has surfaced.
    /// - `.contentTransition(.numericText())` gives Apple-native polish on
    ///   the volatile-to-primary swap (iOS 16+).
    /// - Volatile state is hidden from VoiceOver to avoid re-reading every
    ///   partial; finalized text becomes accessible.
    /// - Animation honors `accessibilityReduceMotion` — falls through to
    ///   instant when Reduce Motion is on.
    @ViewBuilder
    private var streamingPreviewView: some View {
        if (phase == .recording || phase == .transcribing)
            && !streamingPartial.streamingText.isEmpty {
            Text(streamingPartial.streamingText)
                .font(.body)
                .foregroundStyle(streamingPartial.streamingIsVolatile ? .secondary : .primary)
                .contentTransition(.numericText())
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityElement(children: streamingPartial.streamingIsVolatile ? .ignore : .combine)
                .accessibilityLabel(streamingPartial.streamingIsVolatile ? "" : streamingPartial.streamingText)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: streamingPartial.streamingIsVolatile)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: streamingPartial.streamingText)
        }
    }

    private func toggleRecording() {
        errorMessage = nil

        switch phase {
        case .idle:
            if recordingService.isRecording {
                stopAndTranscribe()
            } else {
                startRecording()
            }
        case .recording:
            stopAndTranscribe()
        case .transcribing:
            contentLog.info("Record button tap ignored while transcribing")
        }
    }

    private func startRecording() {
        activeTask?.cancel()
        activeTask = Task {
            let startedAt = Date()

            // 2.5.14 hardening (Cut A §6.3): the Live Activity / Dynamic
            // Island chip is requested BEFORE `recording.start()` activates
            // the audio session, so the system mic indicator and the chip
            // come up paired. Activating the session first would briefly
            // light the orange mic indicator before the chip is rendered;
            // App Review can flag that no-chip window as a 2.5.14
            // disclosure inconsistency. Even though this view is foreground,
            // the user can swipe up / lock during recording — without the
            // activity, the iOS mic indicator becomes the ONLY chrome-side
            // disclosure outside the app.
            //
            // The team-lead brief specifies BEFORE-ordering despite the
            // spec sketch showing AFTER. The brief's no-chip-window concern
            // is the controlling reason; brief-vs-spec conflict resolves in
            // favor of the brief.
            //
            // Trade-off: if `recording.start()` throws, the activity is
            // orphaned. Caught by `cancelPendingRecordingStart()` below.
            await DictationActivityCoordinator.shared.start(startedAt: startedAt)

            do {
                try await recordingService.start()
                await MainActor.run {
                    beginRecordingUI(startedAt: startedAt)
                }
            } catch {
                await DictationActivityCoordinator.shared.cancelPendingRecordingStart()
                await MainActor.run {
                    contentLog.error("Recording start failed: \(error.localizedDescription, privacy: .public)")
                    errorMessage = "Could not start recording: \(error.localizedDescription)"
                    phase = .idle
                    stopVUTimer()
                }
            }
        }
    }

    private func stopAndTranscribe() {
        let recordingStartedAt = startedAt ?? Date()
        stopVUTimer()
        recordingService.markStopInFlight()
        activeTask?.cancel()
        activeTask = Task {
            // Route through the shared `DictationController` +
            // `DictationPipeline.completeEndOfRecording` so the in-app Stop
            // button reaches the same post-recording tail (publish →
            // chained-follow-up classify → append → finish Live Activity)
            // as the keyboard-initiated path. See lean-arch consolidation
            // note on `DictationPipeline.completeEndOfRecording`.
            let controller = DictationIntentBridge.shared.controller
            do {
                await MainActor.run {
                    stopHaptic.impactOccurred()
                    stopHaptic.prepare()
                    phase = .transcribing
                }

                let result = try await controller.stopAndTranscribe()
                let outcome = try await DictationPipeline.completeEndOfRecording(
                    transcript: result.transcript,
                    startedAt: recordingStartedAt,
                    stoppedAt: result.stoppedAt,
                    controller: controller
                )

                await MainActor.run {
                    successHaptic.notificationOccurred(.success)
                    successHaptic.prepare()
                    showCopiedConfirmation(for: outcome.transcriptID)
                    resetRecorderUI()
                }
            } catch {
                await MainActor.run {
                    recordingService.markPipelineFinished()
                    contentLog.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                    errorMessage = "Dictation failed: \(error.localizedDescription)"
                    resetRecorderUI()
                }
            }
        }
    }

    private func syncRecordingState() {
        if recordingService.isRecording, phase != .recording {
            beginRecordingUI(startedAt: Date())
        } else if !recordingService.isRecording, phase == .recording {
            stopVUTimer()
            phase = .idle
            startedAt = nil
            elapsed = 0
        }
    }

    private func beginRecordingUI(startedAt date: Date) {
        startHaptic.impactOccurred()
        startHaptic.prepare()
        startedAt = date
        elapsed = 0
        phase = .recording
        startVUTimer()
    }

    private func resetRecorderUI() {
        phase = .idle
        startedAt = nil
        elapsed = 0
        vuBars = Array(repeating: 0.14, count: 16)
        stopVUTimer()
        // Blank the streaming live preview now that the batch transcript
        // has been published to the persistent history list. The presenter
        // had been holding the post-`finish()` snapshot rendered in
        // `.primary` for the brief pre-batch tail; clearing it prevents
        // the swap from looking like a hover-and-fade duplicate of the
        // freshly-appended row.
        streamingPartial.reset()
    }

    private func startVUTimer() {
        vuTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
            Task { @MainActor in
                guard phase == .recording else { return }
                if let startedAt {
                    elapsed = Date().timeIntervalSince(startedAt)
                }

                var next = vuBars
                next.removeFirst()
                next.append(CGFloat(recordingService.currentAmplitude ?? 0.05))
                vuBars = next
            }
        }
        vuTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopVUTimer() {
        vuTimer?.invalidate()
        vuTimer = nil
    }

    private func copy(_ transcript: Transcript) {
        UIPasteboard.general.string = transcript.displayText
        copyHaptic.impactOccurred()
        copyHaptic.prepare()
        UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard")
        showCopiedConfirmation(for: transcript.id)
    }

    private func showCopiedConfirmation(for id: UUID) {
        copiedTranscriptID = id
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(1_300))
            } catch {
                return
            }
            copiedTranscriptID = nil
        }
    }

    private func delete(_ transcript: Transcript) {
        modelContext.delete(transcript)
        do {
            try modelContext.save()
            TranscriptHistoryMirror.refresh(from: modelContext)
            pendingDeletion = nil
        } catch {
            modelContext.rollback()
            contentLog.error("Transcript delete save failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Could not delete transcript: \(error.localizedDescription)"
            pendingDeletion = nil
        }
    }
}

private enum RecordingPhase: Equatable {
    case idle
    case recording
    case transcribing
}

private struct TranscriptRow: View {
    let transcript: Transcript
    let isCopied: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(transcript.displayText)
                .font(.body)
                .foregroundStyle(.primary)
                .lineLimit(2)

            HStack(spacing: 6) {
                Text(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(durationText)

                if isCopied {
                    Text("·")
                    Label("Copied", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var durationText: String {
        guard let duration = transcript.durationSeconds else { return "--:--" }
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct RecorderBar: View {
    let phase: RecordingPhase
    let elapsed: TimeInterval
    let vuBars: [CGFloat]
    let caption: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if phase == .recording {
                Text(timeString)
                    .font(.footnote.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)

                AmplitudeBars(values: vuBars)
                    .frame(height: 26)
                    .padding(.horizontal, 36)
            }

            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(Color(.secondarySystemGroupedBackground))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Circle()
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 4)
                        )

                    buttonGlyph
                }
            }
            .buttonStyle(.plain)
            .disabled(phase == .transcribing)
            .accessibilityLabel(accessibilityLabel)

            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(minHeight: 18)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var buttonGlyph: some View {
        switch phase {
        case .idle:
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 56, height: 56)
                Image(systemName: "mic.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
            }
        case .recording:
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.red)
                .frame(width: 30, height: 30)
        case .transcribing:
            ProgressView()
                .controlSize(.large)
        }
    }

    private var accessibilityLabel: String {
        switch phase {
        case .idle:
            return "Start recording"
        case .recording:
            return "Stop recording"
        case .transcribing:
            return "Transcribing"
        }
    }

    private var timeString: String {
        let total = max(0, Int(elapsed.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct AmplitudeBars: View {
    let values: [CGFloat]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(Color.red)
                    .frame(width: 3, height: barHeight(for: value))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.linear(duration: 0.08), value: values)
        .accessibilityHidden(true)
    }

    private func barHeight(for value: CGFloat) -> CGFloat {
        5 + max(0, min(1, value)) * 22
    }
}

#Preview {
    ContentView()
        .environment(RecordingService())
        .environment(TranscriptionService())
        .environment(StreamingPartial())
        .modelContainer(for: Transcript.self, inMemory: true)
}
