#if JOT_APP_HOST
import SwiftUI

/// Ask-mode sheet. Single-turn natural-language Q&A over the user's
/// own transcript history, with inline citation chips that link back
/// to the source transcripts.
///
/// Sheet detents: medium + large. Most answers fit medium; expand to
/// large for long responses or to read the cited transcripts disclosure.
struct AskView: View {
    @Bindable var controller: AskController

    /// Citation chip taps push onto this nav path after the sheet
    /// dismisses. Owned by `ContentView` so the destination resolves
    /// through Recents' existing `.navigationDestination(for: UUID.self)`.
    @Binding var navPath: NavigationPath

    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    // Voice-first dictation of the question — reuses Jot's own recording +
    // transcription pipeline (NOT the keyboard). The dictated question is a
    // query, never saved as a transcript. ContentView suppresses the hero
    // while this sheet is up (the `!showAskSheet` guards) so in-sheet
    // recording doesn't push a zombie hero.
    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingPartial.self) private var streamingPartial
    @State private var isDictating = false
    @State private var dictationTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                WallpaperBackground()
                    .ignoresSafeArea()
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Ask Jot")
                            .font(.headline)
                            .foregroundStyle(Color.jotPageInk)
                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.0)
                            .foregroundStyle(Color.jotBlueBottom)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Ask Jot, beta")
                }
            }
            .onAppear {
                controller.refreshAvailability()
                controller.refreshIndexStatus()
                // Voice-first: do NOT auto-raise the keyboard. On a fresh,
                // available Ask, start listening immediately so the default
                // action is "just talk". The user can tap the field to type
                // (which stops + discards the voice).
                if controller.phase == .idle && !isDictating && !recordingService.isRecording {
                    startDictation()
                }
            }
            .onChange(of: inputFocused) { _, focused in
                // Tapping the field = "I want to type" → stop and throw the
                // in-progress voice away so typing starts clean.
                if focused && isDictating {
                    abortDictation()
                    controller.question = ""
                }
            }
            .onDisappear {
                // If the sheet is dismissed mid-dictation, force-stop the
                // recording so it can't leak into a zombie hero once the
                // `!showAskSheet` hero-suppression guards stop applying.
                if isDictating { abortDictation() }
            }
        }
        // Open full-height directly. With `.medium` first, the sheet presented
        // at half then jumped to large the instant `inputFocused` raised the
        // keyboard — a visible two-step "half then full" hitch.
        .presentationDetents([.large])
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .unavailable(let reason):
            unavailableState(reason)
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    questionRow
                    if controller.isIndexing || controller.unindexedCount > 0 {
                        indexBanner
                    }
                    answerArea
                    if !controller.retrievedTranscripts.isEmpty && controller.phase == .done {
                        sourcesFooter
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
    }

    /// Shown inside Ask when notes aren't indexed yet — offers a one-tap index,
    /// with live progress while it runs. (Replaces a launch-time auto-backfill:
    /// the prompt appears where it matters, only when there's something to do.)
    private var indexBanner: some View {
        HStack(spacing: 10) {
            if controller.isIndexing {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Indexing your notes…")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Color.jotPageInk)
                    if controller.indexTotal > 0 {
                        Text("\(controller.indexDone) / \(controller.indexTotal)")
                            .font(.caption2)
                            .foregroundStyle(Color.jotPageInkSecondary)
                    }
                }
                Spacer()
            } else {
                Image(systemName: "sparkles.rectangle.stack")
                    .foregroundStyle(Color.jotBlueBottom)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(controller.unindexedCount) \(controller.unindexedCount == 1 ? "note isn’t" : "notes aren’t") indexed yet")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Color.jotPageInk)
                    Text("Ask already searches them — indexing sharpens the results.")
                        .font(.caption2)
                        .foregroundStyle(Color.jotPageInkSecondary)
                }
                Spacer(minLength: 8)
                Button("Index") { controller.indexUnindexed() }
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Color.jotBlueBottom)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.jotBlueTop.opacity(0.10))
        )
    }

    // MARK: - Question row

    @ViewBuilder
    private var questionRow: some View {
        if controller.phase == .idle || controller.phase == .error("") {
            inputBar
        } else {
            askedQuestionBanner
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.jotBlueBottom)
            TextField(
                "",
                text: $controller.question,
                prompt: Text("Ask anything about your notes…")
                    .foregroundStyle(Color.jotPageInkSecondary),
                axis: .vertical
            )
            .font(.system(size: 15))
            .foregroundStyle(Color.jotPageInk)
            .textInputAutocapitalization(.sentences)
            .submitLabel(.search)
            // Grow with the question up to ~5 lines, then scroll inside — keeps
            // a long (often dictated) question readable in place instead of
            // truncating it on one line.
            .lineLimit(1...5)
            .focused($inputFocused)
            .onSubmit { submitIfPossible() }

            Button {
                if isDictating { stopDictation() } else { startDictation() }
            } label: {
                Image(systemName: isDictating ? "stop.circle.fill" : "mic.fill")
                    .font(.system(size: isDictating ? 26 : 17))
                    .foregroundStyle(isDictating ? Color.red : Color.jotBlueBottom)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            // Don't start a second recording if one is already running elsewhere.
            .disabled(recordingService.isRecording && !isDictating)
            .accessibilityLabel(isDictating ? "Stop dictation" : "Dictate your question")

            Button {
                submitIfPossible()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(
                        canSubmit && !isDictating ? Color.jotBlueBottom : Color.jotPageInkSecondary.opacity(0.4)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || isDictating)
            .accessibilityLabel("Ask")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Rounded-rect (not Capsule) so the bar grows gracefully when the
        // question wraps to multiple lines — a Capsule would turn into an
        // awkward tall stadium. At single-line height this still reads as a pill.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5)
        )
        // Live dictation: stream the partial transcript into the field while
        // recording, exactly like the keyboard's live dictation.
        .onChange(of: streamingPartial.streamingText) { _, newText in
            if isDictating { controller.question = newText }
        }
    }

    private var askedQuestionBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.bubble")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.jotBlueBottom)
            Text(controller.question)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.jotPageInk)
                .lineLimit(3)
            Spacer(minLength: 8)
            if controller.phase == .retrieving || controller.phase == .streaming {
                Button("Cancel") { controller.cancel() }
                    .font(.system(.callout))
                    .foregroundStyle(Color.jotMute)
            } else if controller.phase == .done || controller.phase == .vague {
                Button("Ask another") { controller.reset() }
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Color.jotBlueBottom)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.jotBlueTop.opacity(0.08))
        )
    }

    // MARK: - Answer area

    @ViewBuilder
    private var answerArea: some View {
        switch controller.phase {
        case .idle:
            // While listening with nothing transcribed yet, prompt the user to
            // speak — otherwise an auto-started, empty field gives no cue that
            // it's recording. Disappears the moment the first words land.
            if isDictating && controller.question.isEmpty {
                ListeningRow()
            } else {
                // No example prompts — a clean field; the user asks their own thing.
                EmptyView()
            }
        case .retrieving:
            AskLoadingRow(messages: ["Searching your notes…"])
        case .streaming where controller.segments.isEmpty:
            // The submit→first-token gap. Show "waking the model" while a cold
            // backend loads, then rotate light "thinking" lines during prefill.
            AskLoadingRow(
                messages: controller.isModelWarming
                    ? ["Waking the on-device model…"]
                    : Self.thinkingMessages
            )
        case .streaming, .done:
            answerSegmentsView
        case .vague:
            vagueState
        case .error(let message):
            errorState(message)
        case .unavailable:
            EmptyView()
        }
    }


    /// Light, gently-quirky lines cycled while the model is processing the
    /// prompt before the first token lands. Kept understated on purpose.
    private static let thinkingMessages = [
        "Reading through your notes…",
        "Connecting the dots…",
        "Following the thread…",
        "Piecing it together…",
        "Gathering your thoughts…",
    ]

    private var answerSegmentsView: some View {
        VStack(alignment: .leading, spacing: 0) {
            inlineAnswerText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.jotInk.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.jotInk.opacity(0.10), lineWidth: 0.5)
        )
    }

    /// Renders the segments as a wrapping flow of text and citation
    /// chips. v1 uses a simple `Text` concatenation — citation chips
    /// are styled as small inline runs with an inline `Image`. Tap
    /// handling: SwiftUI's `Text` concatenation doesn't propagate
    /// per-run taps, so we wrap each citation chip as its own Button
    /// rendered alongside the text via a custom approach: we split the
    /// answer into "line groups" at newlines and lay each group as an
    /// HStack of mixed Text + chip Buttons. Simple and ships.
    private var inlineAnswerText: some View {
        let groups = groupSegmentsByLine(controller.segments)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                lineView(for: group)
            }
        }
    }

    /// One logical line — wraps with `Text` concatenation, except for
    /// citation chips which are rendered as tappable Button views
    /// inline via a custom layout.
    @ViewBuilder
    private func lineView(for line: [AskAnswerSegment]) -> some View {
        FlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(line) { segment in
                switch segment {
                case .text(let s):
                    if !s.isEmpty {
                        Text(s)
                            .font(.system(size: 15))
                            .foregroundStyle(Color.jotPageInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .citation(let id, let label):
                    Button {
                        openCitation(id: id)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.text.fill")
                                .font(.system(size: 9, weight: .semibold))
                            Text(label)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color.jotBlueBottom)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.jotBlueTop.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Source: transcript dated \(label). Tap to open.")
                }
            }
        }
    }

    // MARK: - Sources footer

    private var sourcesFooter: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(controller.retrievedTranscripts) { transcript in
                    Button {
                        openCitation(id: transcript.id)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: controller.citedIDs.contains(transcript.id)
                                  ? "checkmark.circle.fill"
                                  : "circle")
                                .font(.system(size: 12))
                                .foregroundStyle(controller.citedIDs.contains(transcript.id)
                                                 ? Color.jotBlueBottom
                                                 : Color.jotPageInkSecondary.opacity(0.5))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(transcript.displayText)
                                    .font(.caption)
                                    .foregroundStyle(Color.jotPageInk)
                                    .lineLimit(1)
                                Text(transcript.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(Color.jotPageInkSecondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 4)
        } label: {
            Text(sourcesFooterLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .padding(.horizontal, 4)
    }

    private var sourcesFooterLabel: String {
        let sources = controller.citedIDs.count
        let retrieved = controller.retrievedTranscripts.count
        var label = "\(sources) source\(sources == 1 ? "" : "s") · \(retrieved) retrieved"
        if let backend = controller.answerBackend {
            label += " · \(backend.displayName)"
        }
        return label
    }

    // MARK: - State views

    private var vagueState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("That question was a bit vague.")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)
            Text("Try mentioning a topic, a person, or a time frame.")
                .font(.system(.callout))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .padding(.horizontal, 4)
    }

    private func errorState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Something went wrong")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Color.jotPageInk)
            }
            Text(message)
                .font(.system(.callout))
                .foregroundStyle(Color.jotPageInkSecondary)
            Button("Try again") { submitIfPossible() }
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Color.jotBlueBottom)
                .padding(.top, 4)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.orange.opacity(0.10))
        )
    }

    private func unavailableState(_ reason: AskController.UnavailableReason) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.jotPageInkSecondary)
                Text(reason == .qwenNotDownloaded
                     ? "Ask needs the on-board model"
                     : "Ask uses Apple Intelligence")
                    .font(.headline)
                    .foregroundStyle(Color.jotPageInk)
            }
            Text(unavailableMessage(reason))
                .font(.system(.callout))
                .foregroundStyle(Color.jotPageInkSecondary)
            if reason == .appleIntelligenceOff {
                Button {
                    openSystemSettings()
                } label: {
                    Text("Open Settings")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(
                                LinearGradient(
                                    colors: [Color.jotBlueTop, Color.jotBlueBottom],
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func unavailableMessage(_ reason: AskController.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceOff:
            return "Apple Intelligence is turned off. Turn it on in Settings, or switch Ask to on-board Qwen in Settings → AI."
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence. Switch Ask to on-board Qwen in Settings → AI."
        case .modelDownloading:
            return "Apple Intelligence is still downloading. Try again in a few minutes, or switch Ask to on-board Qwen in Settings → AI."
        case .qwenNotDownloaded:
            return "On-board Qwen isn't downloaded. Download it in Settings → AI → Rewrite & prompts, or switch Ask to Apple Intelligence in Settings → AI."
        case .unknown:
            return "Ask isn't available right now. Try again in a moment."
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Helpers

    private var canSubmit: Bool {
        !controller.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (controller.phase == .idle || isErrorPhase(controller.phase))
    }

    private func isErrorPhase(_ phase: AskController.Phase) -> Bool {
        if case .error = phase { return true }
        return false
    }

    private func submitIfPossible() {
        guard canSubmit else { return }
        controller.ask()
    }

    // MARK: - Voice dictation (transient — never saved as a transcript)

    private func startDictation() {
        guard !recordingService.isRecording else { return }
        inputFocused = false
        controller.question = ""
        isDictating = true
        // Claim ownership so the home view won't adopt this recording as a hero
        // (it shares the same recorder). Cleared only once teardown completes.
        controller.ownsActiveRecording = true
        dictationTask = Task {
            do {
                // `start()` returns once recording is live; partials then flow
                // through `streamingPartial.streamingText` into the field.
                try await recordingService.start()
            } catch {
                isDictating = false
                controller.ownsActiveRecording = false
            }
        }
    }

    private func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        let pending = dictationTask
        dictationTask = Task {
            // Let an in-flight start() finish before stopping — cancelling it
            // mid-bring-up races the engine and can leak a live recording.
            _ = await pending?.result
            do {
                let samples = try await recordingService.stop()
                // Ask transcribes the samples itself and never runs
                // RecordingService's normal post-stop pipeline, so we must
                // release the pipeline-in-flight latch by hand. Without this the
                // next real dictate throws "a recording is already in progress".
                recordingService.markPipelineFinished()
                // Recording is fully stopped — release ownership so the home can
                // resume normal recording behavior.
                controller.ownsActiveRecording = false
                let text = try await transcriptionService.transcribe(samples: samples)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    controller.question = trimmed
                    // Auto-run the answer on stop — speak → stop → answer.
                    submitIfPossible()
                }
                // NOTE: deliberately NOT calling TranscriptStore.append — the
                // dictated question is a query, not a note. No corpus pollution.
            } catch {
                // stop() failed (its own catch already released the latch) or
                // transcription threw — release defensively so we never wedge
                // the recorder for the next dictation.
                recordingService.markPipelineFinished()
                controller.ownsActiveRecording = false
            }
        }
    }

    /// Force-stop a recording started by the mic without submitting (used when
    /// the sheet is dismissed mid-dictation). Discards the audio.
    private func abortDictation() {
        isDictating = false
        let pending = dictationTask
        dictationTask = nil
        Task {
            // Let an in-flight start() finish so the teardown sees a live engine
            // to release — discarding mid-bring-up would leak the recording.
            _ = await pending?.result
            // forceStop() discards the captured audio AND fully releases the mic
            // (unlike cancel(), it does NOT re-enter warm-hold) — the true
            // "throw it away" for closing Ask / switching to typing, so the mic
            // doesn't linger after. It never calls stop(), so the
            // pipeline-in-flight latch is never set. `.failed` here is a benign
            // terminal phase (handled like `.idle`), not a user-facing error.
            recordingService.forceStop()
            // Teardown complete — release ownership so the home (and the next
            // real dictate) can use the recorder normally.
            controller.ownsActiveRecording = false
        }
    }

    private func openCitation(id: UUID) {
        dismiss()
        // 150ms dispatch — gives the sheet a moment to tear down so
        // the push doesn't race the dismissal. Same pattern as the
        // rewrite handoff path in JotApp.swift.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            navPath.append(id)
        }
    }

    private func groupSegmentsByLine(_ segments: [AskAnswerSegment]) -> [[AskAnswerSegment]] {
        var lines: [[AskAnswerSegment]] = []
        var current: [AskAnswerSegment] = []
        for segment in segments {
            switch segment {
            case .text(let s):
                let parts = s.components(separatedBy: "\n")
                for (idx, part) in parts.enumerated() {
                    if !part.isEmpty {
                        current.append(.text(part))
                    }
                    if idx < parts.count - 1 {
                        lines.append(current)
                        current = []
                    }
                }
            case .citation:
                current.append(segment)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

// MARK: - FlowLayout

/// Wrapping HStack — lays out children left-to-right, wrapping to the
/// next line when the available width is exceeded. Needed because
/// SwiftUI's stock `HStack` doesn't wrap.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let result = arrange(subviews: subviews, maxWidth: maxWidth)
        return CGSize(width: maxWidth.isFinite ? maxWidth : result.maxX, height: result.maxY)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let placements = arrangePlacements(subviews: subviews, maxWidth: maxWidth)
        for placement in placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private struct Placement {
        let index: Int
        let x: CGFloat
        let y: CGFloat
        let size: CGSize
    }

    private struct ArrangeResult {
        let maxX: CGFloat
        let maxY: CGFloat
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> ArrangeResult {
        let widthProposal = ProposedViewSize(width: maxWidth, height: nil)
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(widthProposal)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxX = max(maxX, x)
        }
        return ArrangeResult(maxX: maxX, maxY: y + lineHeight)
    }

    private func arrangePlacements(subviews: Subviews, maxWidth: CGFloat) -> [Placement] {
        let widthProposal = ProposedViewSize(width: maxWidth, height: nil)
        var placements: [Placement] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for (index, sv) in subviews.enumerated() {
            let size = sv.sizeThatFits(widthProposal)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            placements.append(Placement(index: index, x: x, y: y, size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return placements
    }
}

/// "Listening" status shown below the field while dictation is live but no
/// words have been transcribed yet — a pulsing record dot + a nudge to speak.
private struct ListeningRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 9, height: 9)
                .opacity(pulse ? 0.3 : 1.0)
            Text("Listening… ask about your notes")
                .font(.system(.callout))
                .foregroundStyle(Color.jotPageInkSecondary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Spinner + a single rotating status line. With one message it sits static
/// (e.g. "Searching…", "Waking the model…"); with several it cross-fades
/// through them on a gentle cadence while the model is thinking. The rotation
/// task is keyed on `messages`, so swapping pools (warming → thinking) restarts
/// it cleanly, and it cancels automatically when the row leaves the tree (first
/// token arrives).
private struct AskLoadingRow: View {
    let messages: [String]
    @State private var index = 0

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(messages.indices.contains(index) ? messages[index] : (messages.first ?? ""))
                .font(.system(.callout))
                .foregroundStyle(Color.jotPageInkSecondary)
                .id(index)
                .transition(.opacity)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .task(id: messages) {
            index = 0
            guard messages.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_200_000_000)
                if Task.isCancelled { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    index = (index + 1) % messages.count
                }
            }
        }
    }
}
#endif
