#if JOT_APP_HOST
import SwiftUI

/// Ask-mode sheet — voice-first natural-language Q&A over the user's own
/// transcript history. One full-height sheet that morphs through a three-phase
/// lifecycle: **listening → thinking → answer** (the redesign handoff,
/// `ask-jot-redsign/`). Opening the sheet starts listening immediately; the
/// live transcript becomes the on-screen hero; after a short silence the
/// question auto-sends; the grounded answer streams in as flowing typeset text
/// with inline citation chips and a Sources list.
///
/// This file is the **view layer only** — all retrieval / streaming / citation
/// / indexing / backend logic lives in `AskController`, untouched by the
/// redesign. The dictation plumbing (auto-start, live partials, silence
/// auto-send, recording ownership, citation nav) is preserved verbatim from the
/// previous implementation; only the visual structure changed.
struct AskView: View {
    @Bindable var controller: AskController

    /// Citation chip taps push onto this nav path after the sheet dismisses.
    /// Owned by `ContentView` so the destination resolves through Recents'
    /// existing `.navigationDestination(for: UUID.self)`.
    @Binding var navPath: NavigationPath

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool

    // Voice-first dictation of the question — reuses Jot's own recording +
    // transcription pipeline (NOT the keyboard). The dictated question is a
    // query, never saved as a transcript. ContentView suppresses the hero while
    // this sheet is up (the `!showAskSheet` guards) so in-sheet recording
    // doesn't push a zombie hero.
    @Environment(RecordingService.self) private var recordingService
    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingPartial.self) private var streamingPartial
    @State private var isDictating = false
    /// Shared inline-dictation lifecycle — the same `InlineDictationSession` the
    /// keyboard-in-Jot receiver uses. Ask's only difference is the terminal: the
    /// transcribed text becomes a submitted question, not a field insert.
    @State private var dictationSession: InlineDictationSession?

    /// `Type instead` mode — swaps the voice canvas for a typed textarea. Toggled
    /// by the dock button; entering it discards any in-progress voice transcript.
    @State private var typing = false
    /// Copy-confirmation flash on the answer dock's Copy control.
    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    // Auto-send on silence (voice-first): once the user has actually spoken
    // (first words transcribed), `silenceAutoSendSeconds` of continuous quiet
    // auto-finishes the question via the SAME terminal as the Send/Stop button
    // (`stopDictation` → finalize + submit). Speaking resets the timer; a short
    // grace before the countdown shows keeps inter-word pauses from flashing it.
    @State private var secondsUntilAutoSend: Int?
    @State private var silenceMonitor: Task<Void, Never>?
    private static let silenceAutoSendSeconds: Double = 5
    /// Normalized RMS at or below this reads as silence (tunable on-device).
    private static let speechAmplitudeThreshold: Float = 0.08
    /// Wait this long into a silence before showing the countdown.
    private static let countdownGrace: Double = 1.0

    // MARK: - Design tokens (handoff §Design Tokens, mapped to app tokens)

    /// Adaptive accent for small text / chips / caret / dots / waveform. The
    /// handoff specifies `#0E7AE6` (solid) and `#1A8CFF` (dot) for both themes,
    /// but those clear WCAG only on the handoff's own light sheet; on Jot's
    /// lighter page base small accent text dips to ~2.8:1. So we shift per-mode —
    /// darker brand-blue (`#0064CC`) in light for legible small text, brighter
    /// (`#1A8CFF`) in dark — while staying on the brand-blue ramp. Large gradient
    /// fills (send button, CTA) keep the full `jotBlueTop → jotBlueBottom` ramp.
    static let accentInk = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 0x1A / 255, green: 0x8C / 255, blue: 1.0, alpha: 1)
            : UIColor(red: 0x00 / 255, green: 0x64 / 255, blue: 0xCC / 255, alpha: 1)
    })
    /// `accent.soft` (handoff `rgba(26,140,255,0.20)`).
    private static let accentSoft = Color.jotBlueTop.opacity(0.20)
    /// `accent.glow` for the send / CTA shadows (handoff `rgba(26,140,255,0.44)`).
    private static let accentGlow = Color.jotBlueTop.opacity(0.44)
    /// The brand gradient — handoff `#2E9BFF → #0E7AE6 → #0064CC`, served by the
    /// app's existing `jotBlueTop → jotBlueBottom` brand pair.
    private static let accentGradient = LinearGradient(
        colors: [Color.jotBlueTop, Color.jotBlueBottom],
        startPoint: .top, endPoint: .bottom
    )

    /// Header chrome height + top inset (handoff: header height 56 at top 16).
    private static let headerTopInset: CGFloat = 16
    private static let headerHeight: CGFloat = 56

    var body: some View {
        ZStack(alignment: .top) {
            WallpaperBackground()
                .ignoresSafeArea()

            content
                .padding(.top, Self.headerTopInset + Self.headerHeight + 12)

            askHeader
        }
        .onAppear {
            controller.refreshAvailability()
            controller.refreshIndexStatus()
            // Voice-first: do NOT auto-raise the keyboard. On a fresh, available
            // Ask, start listening immediately so the default action is "just
            // talk". The user taps `Type instead` to switch to typing.
            if controller.phase == .idle && !isDictating && !recordingService.isRecording {
                startDictation()
            }
        }
        .onChange(of: streamingPartial.streamingText) { _, newText in
            // Live dictation: stream the partial transcript into the hero while
            // recording, exactly like the keyboard's live dictation.
            if isDictating { controller.question = newText }
        }
        .onDisappear {
            // Closing Ask releases the mic — in every state, but gently:
            //  • Mid-dictation → `abortDictation()` discards the in-progress
            //    question audio (it's a query, never saved) and releases the mic
            //    (awaits the in-flight start first, so the rapid open/close race
            //    can't leak a recording).
            //  • After a SENT question with Warm Hold on → the mic is warm-held
            //    (finalize → stop), so `isDictating` is already false.
            //    `releaseWarmHold()` exits warm-hold cleanly — NOT a force-stop.
            //    Ask is a query, not a dictation to continue, so closing it
            //    shouldn't leave the mic warm.
            // The controller is intentionally NOT reset here: the answer persists
            // so reopening Ask resumes where you left off (tap "Ask another" for
            // a fresh session).
            if isDictating {
                abortDictation()
            } else {
                recordingService.releaseWarmHold()
            }
            copyResetTask?.cancel()
        }
        // Open full-height directly. A `.medium`-first detent made the sheet jump
        // half→full the instant the keyboard raised — a visible two-step hitch.
        .presentationDetents([.large])
    }

    // MARK: - Header (all phases) — Done · Ask Jot · BETA

    private var askHeader: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("Ask Jot")
                    .font(.system(size: 18, weight: .bold))
                    .tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)
                Text("BETA")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(Self.accentInk)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Ask Jot, beta")

            HStack {
                Button { dismiss() } label: {
                    Text("Done")
                        .font(.system(size: 16.5, weight: .medium))
                        .foregroundStyle(Color.jotPageInk)
                        .padding(.horizontal, 17)
                        .frame(height: 38)
                        .modifier(JotDesign.Surface.key.modifier(cornerRadius: 19))
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.leading, 18)
        }
        .frame(height: Self.headerHeight)
        .padding(.top, Self.headerTopInset)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Phase routing

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .unavailable(let reason):
            unavailableState(reason)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .idle:
            listeningCanvas
        case .retrieving:
            thinkingView
        case .streaming where controller.segments.isEmpty:
            thinkingView
        case .streaming, .done:
            answerView
        case .vague:
            edgeStateScaffold { vagueState }
        case .error(let message):
            edgeStateScaffold { errorState(message) }
        }
    }

    /// Wraps the small edge states (vague / error) under a question header so the
    /// user still sees what they asked, consistent with thinking / answer.
    @ViewBuilder
    private func edgeStateScaffold<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            AskQuestionHeader(
                question: controller.question,
                trailingLabel: "Ask another",
                trailingAction: { askAnother() }
            )
            body()
                .padding(.horizontal, 22)
                .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: - Phase 1 · Listening (voice canvas)

    private var listeningCanvas: some View {
        VStack(spacing: 0) {
            if controller.isIndexing || controller.unindexedCount > 0 {
                indexBanner
                    .padding(.horizontal, 18)
                    .padding(.bottom, 4)
            }

            // Hero — empty prompt + rotating suggestion, or the live transcript.
            VStack { heroZone }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 34)

            // Status zone (height 40): countdown ring / Listening+waveform /
            // typing label.
            statusZone
                .frame(height: 40)
                .padding(.bottom, 6)

            // Dock — single send-stop control + Type-instead toggle.
            VStack(spacing: 13) {
                AskSendStop(
                    ready: hasWords,
                    size: 60,
                    gradient: Self.accentGradient,
                    glow: Self.accentGlow,
                    action: sendStop
                )
                .accessibilityLabel(typing ? "Ask" : "Stop and ask")

                Button(action: toggleTyping) {
                    HStack(spacing: 7) {
                        Image(systemName: typing ? "waveform" : "keyboard")
                            .font(.system(size: 15, weight: .medium))
                        Text(typing ? "Use voice" : "Type instead")
                            .font(.system(size: 14.5, weight: .medium))
                    }
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
            .padding(.bottom, 30)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var heroZone: some View {
        if typing {
            // Typed question — same SF Pro hero style as the transcript.
            TextField(
                "",
                text: $controller.question,
                prompt: Text("Type your question…").foregroundStyle(Color.jotPageInkSecondary),
                axis: .vertical
            )
            .font(.system(size: 30, weight: .regular, design: .default))
            .foregroundStyle(Color.jotPageInk)
            .multilineTextAlignment(.center)
            .textInputAutocapitalization(.sentences)
            .lineLimit(1...4)
            .focused($inputFocused)
            .submitLabel(.search)
            .onSubmit { submitIfPossible() }
        } else if hasWords {
            // Live transcript IS the hero.
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(controller.question)
                    .font(.system(size: 30, weight: .regular, design: .default))
                    .tracking(-0.4)
                    .lineSpacing(4)
                    .foregroundStyle(Color.jotPageInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                AskCaret(width: 2.5, height: 28, color: Self.accentInk)
            }
        } else {
            // Empty — pulsing sparkle, prompt, rotating spoken-aloud suggestion.
            VStack(spacing: 22) {
                AskPulse {
                    Image(systemName: "sparkles")
                        .font(.system(size: 34))
                        .foregroundStyle(Self.accentInk)
                }
                Text("What do you want to know?")
                    .font(.system(size: 25, weight: .regular, design: .default))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .multilineTextAlignment(.center)
                AskSuggestionLine()
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var statusZone: some View {
        if typing {
            Text("Voice paused · typing")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotPageInkCaption)
        } else if let seconds = secondsUntilAutoSend {
            AskCountdownRing(seconds: seconds, total: Int(Self.silenceAutoSendSeconds), accent: Self.accentInk)
        } else if hasWords {
            HStack(spacing: 11) {
                HStack(spacing: 7) {
                    AskPulse(duration: 1.4) {
                        Circle().fill(Self.accentInk).frame(width: 9, height: 9)
                    }
                    Text("Listening")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(Color.jotPageInk)
                }
                AskWaveform(color: Self.accentInk, active: !reduceMotion, scale: 0.62)
            }
        }
    }

    // MARK: - Phase 2 · Thinking

    private var thinkingView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No header pill — closing the sheet (Done) is the way out; a
            // separate Cancel pill was removed at the user's request.
            AskQuestionHeader(question: controller.question)
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    AskPulse(duration: 1.1) {
                        Circle().fill(Self.accentInk).frame(width: 9, height: 9)
                    }
                    AskThinkingStatus(steps: thinkingSteps)
                }
                // Shimmer skeleton — 4 lines.
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array([1.0, 0.96, 0.88, 0.70].enumerated()), id: \.offset) { _, w in
                        AskShimmerLine(widthFraction: w, animate: !reduceMotion)
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 26)
            .padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Thinking status steps. "Reading N notes" uses the real retrieved count
    /// once retrieval lands (0 until then → the model is still warming on a cold
    /// backend, so we show the warming copy instead).
    private var thinkingSteps: [String] {
        if controller.isModelWarming {
            return ["Waking the on-device model…"]
        }
        let n = controller.retrievedTranscripts.count
        var steps = ["Searching your notes…"]
        if n > 0 { steps.append("Reading \(n) \(n == 1 ? "note" : "notes")…") }
        steps.append("Writing your answer…")
        return steps
    }

    // MARK: - Phase 3 · Answer (typeset)

    private var answerView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No header pill in any answer state — the bottom "Ask another" CTA
            // covers a fresh question and Done closes the sheet. The Cancel pill
            // was removed at the user's request.
            AskQuestionHeader(question: controller.question)

            // Auto-routed help answers carry a small provenance label so the user
            // knows this came from Jot's help, not their own notes. Shown the whole
            // time the help answer is on screen (streaming + done).
            if controller.answerCorpus == .help {
                helpProvenanceLabel
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    typesetAnswer
                    if controller.phase == .done {
                        sourcesSection
                            .padding(.top, 26)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.top, 20)
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if controller.phase == .done {
                answerDock
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// Small "From Jot's Help" provenance chip for auto-routed product-help
    /// answers. Not a citation — just tells the user which source answered.
    private var helpProvenanceLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 11, weight: .semibold))
            Text("From Jot's Help")
                .font(.system(size: 12, weight: .semibold))
                .tracking(0.2)
        }
        .foregroundStyle(Self.accentInk)
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .accessibilityLabel("Answered from Jot's help, not your notes.")
    }

    /// Flowing typeset answer — no card. Wraps text and inline citation chips,
    /// with a trailing block caret while still streaming.
    private var typesetAnswer: some View {
        let groups = groupSegmentsByLine(controller.segments)
        let lastIndex = groups.count - 1
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(groups.enumerated()), id: \.offset) { idx, group in
                lineView(for: group, showCaret: idx == lastIndex && controller.phase == .streaming)
            }
        }
    }

    /// One logical line — text + inline tappable citation chips, laid out with a
    /// wrapping `FlowLayout`.
    @ViewBuilder
    private func lineView(for line: [AskAnswerSegment], showCaret: Bool) -> some View {
        FlowLayout(spacing: 3, lineSpacing: 7) {
            ForEach(line) { segment in
                switch segment {
                case .text(let s):
                    if !s.isEmpty {
                        Text(s)
                            .font(.system(size: 17.5))
                            .tracking(-0.1)
                            .foregroundStyle(Color.jotPageInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .citation(let id, let label):
                    Button { openCitation(id: id) } label: {
                        AskCitationChip(label: label, accent: Self.accentInk, soft: Self.accentSoft)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Source: transcript dated \(label). Tap to open.")
                }
            }
            if showCaret {
                AskCaret(width: 8, height: 18, color: Self.accentInk)
            }
        }
    }

    // MARK: - Sources section

    @ViewBuilder
    private var sourcesSection: some View {
        // Prefer the notes the model actually cited (inline `[cite: N]` chips).
        // But some answers — especially "list / summarize the notes about X" —
        // enumerate sources in prose without the citation markers, so nothing
        // parses into `citedIDs`. In that case fall back to the retrieved notes
        // so the sources are ALWAYS visible and openable (restores the prior
        // "show the notes" behaviour). Cited path stays clean; fallback covers
        // the un-cited list-style answers.
        let cited = controller.retrievedTranscripts.filter { controller.citedIDs.contains($0.id) }
        let sources = cited.isEmpty ? controller.retrievedTranscripts : cited
        VStack(alignment: .leading, spacing: 0) {
            if !sources.isEmpty {
                HStack(spacing: 8) {
                    Text("SOURCES")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.4)
                        .foregroundStyle(Color.jotPageInkCaption)
                    Rectangle()
                        .fill(Color.jotPageInk.opacity(0.11))
                        .frame(height: 1)
                }
                .padding(.bottom, 4)

                ForEach(Array(sources.enumerated()), id: \.element.id) { idx, transcript in
                    if idx > 0 {
                        Rectangle()
                            .fill(Color.jotPageInk.opacity(0.11))
                            .frame(height: 0.5)
                            .padding(.horizontal, 4)
                    }
                    Button { openCitation(id: transcript.id) } label: {
                        AskSourceRow(
                            date: Self.sourceDateString(transcript.createdAt),
                            snippet: transcript.displayText,
                            accent: Self.accentInk,
                            soft: Self.accentSoft
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(attributionLine)
                .font(.system(size: 13))
                .foregroundStyle(Color.jotPageInkCaption)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 12)
        }
        .transition(.opacity)
    }

    private var attributionLine: String {
        // Product-help answers searched the bundled help corpus, not the user's
        // notes — never claim "N notes searched" for them.
        if controller.answerCorpus == .help {
            if let model = controller.answerBackend?.displayName {
                return "Answered from Jot's Help with \(model) · on-device"
            }
            return "Answered from Jot's Help · on-device"
        }
        let n = controller.retrievedTranscripts.count
        let searched = "\(n) \(n == 1 ? "note" : "notes") searched · on-device"
        if let model = controller.answerBackend?.displayName {
            return "Answered with \(model) · \(searched)"
        }
        return "Answered on-device · \(searched)"
    }

    private static func sourceDateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }

    // MARK: - Answer action dock

    private var answerDock: some View {
        HStack(spacing: 11) {
            Button { askAnother() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18))
                    Text("Ask another")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Self.accentGradient, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.30), lineWidth: 0.5).blendMode(.plusLighter))
                .shadow(color: Self.accentGlow, radius: 12, x: 0, y: 8)
            }
            .buttonStyle(.plain)

            Button(action: copyAnswer) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 18, weight: copied ? .semibold : .regular))
                    .foregroundStyle(copied ? Self.accentInk : Color.jotPageInk)
                    .frame(width: 54, height: 54)
                    .modifier(JotDesign.Surface.key.modifier(cornerRadius: 27))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Copy answer")
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 28)
        .transition(.opacity)
    }

    // MARK: - Index prompt (offered inside Ask when notes aren't indexed)

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
                    .foregroundStyle(Self.accentInk)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(controller.unindexedCount) \(controller.unindexedCount == 1 ? "note isn’t" : "notes aren’t") indexed yet")
                        .font(.system(.callout, weight: .semibold))
                        .foregroundStyle(Color.jotPageInk)
                    Text("Ask already searches them — indexing sharpens results.")
                        .font(.caption2)
                        .foregroundStyle(Color.jotPageInkSecondary)
                }
                Spacer(minLength: 8)
                Button("Index") { controller.indexUnindexed() }
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Self.accentInk)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Self.accentSoft.opacity(0.5))
        )
    }

    // MARK: - Edge states (vague / error / unavailable)

    private var vagueState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("That question was a bit vague.")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)
            Text("Try mentioning a topic, a person, or a time frame.")
                .font(.system(.callout))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .foregroundStyle(Self.accentInk)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                        .background(Capsule().fill(Self.accentGradient))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
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

    private var hasWords: Bool {
        !controller.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        hasWords && (controller.phase == .idle || isErrorPhase(controller.phase))
    }

    private func isErrorPhase(_ phase: AskController.Phase) -> Bool {
        if case .error = phase { return true }
        return false
    }

    private func submitIfPossible() {
        guard canSubmit else { return }
        controller.ask()
    }

    /// The single send-stop control: in voice mode it stops + finalizes + submits;
    /// in typing mode it submits the typed question.
    private func sendStop() {
        guard hasWords else { return }
        if typing {
            submitIfPossible()
        } else {
            stopDictation()
        }
    }

    /// `Type instead` ⇄ `Use voice`. Entering typing discards the in-progress
    /// voice transcript (handoff: "clearing the voice transcript").
    private func toggleTyping() {
        if typing {
            typing = false
            inputFocused = false
            controller.question = ""
            startDictation()
        } else {
            abortDictation()
            controller.question = ""
            typing = true
            inputFocused = true
        }
    }

    /// "Ask another" — reset to a FRESH listening session (voice-first), exactly
    /// like opening the sheet. Without re-arming dictation the redesign's idle
    /// canvas would sit silent with a disabled send button (the old idle UI had a
    /// separate mic button; the single-button design relies on auto-listening).
    private func askAnother() {
        controller.reset()
        typing = false
        inputFocused = false
        startDictation()
    }

    private func copyAnswer() {
        UIPasteboard.general.string = plainAnswerText
        copyResetTask?.cancel()
        copied = true
        copyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }

    /// The answer as plain prose (citation chips dropped) for the Copy control.
    private var plainAnswerText: String {
        controller.segments.reduce(into: "") { acc, segment in
            if case .text(let s) = segment { acc += s }
        }.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Voice dictation (transient — never saved as a transcript)

    private func startDictation() {
        guard !recordingService.isRecording else { return }
        inputFocused = false
        controller.question = ""
        isDictating = true
        // The session claims ownership (so home won't adopt this as a hero),
        // awaits the in-flight start before any terminal, releases the
        // pipeline-in-flight latch, and force-stops on discard. Partials flow
        // through `streamingPartial.streamingText` into the question (onChange).
        let session = InlineDictationSession(
            recordingService: recordingService,
            transcribe: { [transcriptionService] samples in
                try await transcriptionService.transcribe(samples: samples)
            }
        )
        dictationSession = session
        session.start()
        startSilenceMonitor()
    }

    private func stopDictation() {
        guard isDictating else { return }
        isDictating = false
        stopSilenceMonitor()
        let session = dictationSession
        dictationSession = nil
        Task {
            // `finalize()` stops, transcribes, and releases the latch + ownership.
            // Ask's terminal: set the question and auto-run the answer (speak →
            // stop → answer). NOT saved as a transcript — it's a query.
            if let text = await session?.finalize() {
                controller.question = text
                submitIfPossible()
            }
        }
    }

    /// Stop the mic without submitting (sheet dismissed mid-dictation, or
    /// switching to typing). Uses the GENTLE stop — the same clean stop every
    /// other surface uses, which honours Warm Hold per the user's setting —
    /// NOT a force-stop. The in-progress question audio is dropped (never saved,
    /// never submitted); only the mic is released.
    private func abortDictation() {
        isDictating = false
        stopSilenceMonitor()
        let session = dictationSession
        dictationSession = nil
        session?.stopGently()
    }

    /// Watches the live mic amplitude while dictating. Once the user has spoken
    /// (first words transcribed), `silenceAutoSendSeconds` of continuous quiet
    /// auto-finishes the question via `stopDictation()` (finalize + submit). Any
    /// speech resets the timer; the countdown surfaces only after a short grace
    /// so inter-word pauses don't flash it.
    @MainActor
    private func startSilenceMonitor() {
        silenceMonitor?.cancel()
        secondsUntilAutoSend = nil
        silenceMonitor = Task { @MainActor in
            var hasSpoken = false
            var lastVoiceAt = Date()
            while !Task.isCancelled, isDictating {
                let amp = recordingService.currentAmplitude ?? 0
                let now = Date()
                let speaking = amp > Self.speechAmplitudeThreshold
                if speaking { lastVoiceAt = now }
                if !controller.question.isEmpty { hasSpoken = true }
                if hasSpoken, !speaking {
                    let silent = now.timeIntervalSince(lastVoiceAt)
                    if silent >= Self.silenceAutoSendSeconds {
                        secondsUntilAutoSend = nil
                        stopDictation() // finalize + submit — same as the Send/Stop button
                        return
                    } else if silent >= Self.countdownGrace {
                        let remaining = Int(ceil(Self.silenceAutoSendSeconds - silent))
                        if secondsUntilAutoSend != remaining { secondsUntilAutoSend = remaining }
                    } else if secondsUntilAutoSend != nil {
                        secondsUntilAutoSend = nil
                    }
                } else if secondsUntilAutoSend != nil {
                    secondsUntilAutoSend = nil
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func stopSilenceMonitor() {
        silenceMonitor?.cancel()
        silenceMonitor = nil
        secondsUntilAutoSend = nil
    }

    private func openCitation(id: UUID) {
        dismiss()
        // 150ms dispatch — gives the sheet a moment to tear down so the push
        // doesn't race the dismissal. Same pattern as the rewrite handoff path.
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

// MARK: - Atoms

/// Blinking block caret (1s step-end). Hidden under Reduce Motion (stays solid).
private struct AskCaret: View {
    let width: CGFloat
    let height: CGFloat
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = true

    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
            .opacity(on ? 1 : 0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.55).repeatForever(autoreverses: true)) {
                    on = false
                }
            }
    }
}

/// Gentle breathe (opacity) pulse used on the sparkle / live dots.
private struct AskPulse<Content: View>: View {
    var duration: Double = 2.4
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        content
            .opacity(pulse ? 0.35 : 1.0)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: duration / 2).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}

/// Reactive listening waveform — 7 bars scaling on staggered loops.
private struct AskWaveform: View {
    let color: Color
    let active: Bool
    var scale: CGFloat = 1

    private static let bars: [(height: CGFloat, duration: Double)] = [
        (13, 0.70), (22, 0.90), (17, 0.60), (26, 0.80), (15, 0.70), (21, 1.00), (13, 0.65)
    ]
    @State private var animating = false

    var body: some View {
        HStack(spacing: 4 * scale) {
            ForEach(Array(Self.bars.enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(color)
                    .frame(width: 3.5 * scale, height: bar.height * scale)
                    .scaleEffect(x: 1, y: active ? (animating ? 1.0 : 0.4) : 0.3, anchor: .center)
                    .opacity(active ? 1 : 0.4)
                    .animation(
                        active
                            ? .easeInOut(duration: bar.duration).repeatForever(autoreverses: true)
                            : .default,
                        value: animating
                    )
            }
        }
        .frame(height: 28 * scale)
        .onAppear { if active { animating = true } }
        .onChange(of: active) { _, now in animating = now }
    }
}

/// 5-second silence countdown — ring track + accent progress arc with the
/// remaining seconds centered, beside the "keep talking" label.
private struct AskCountdownRing: View {
    let seconds: Int
    let total: Int
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .stroke(
                        colorScheme == .dark ? Color.white.opacity(0.14) : Color(red: 40/255, green: 54/255, blue: 82/255).opacity(0.14),
                        lineWidth: 3
                    )
                Circle()
                    .trim(from: 0, to: max(0, min(1, CGFloat(seconds) / CGFloat(total))))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // Under Reduce Motion the arc snaps each second (no sweep); the
                    // number still updates so the countdown stays legible.
                    .animation(reduceMotion ? nil : .linear(duration: 1), value: seconds)
                Text("\(seconds)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .frame(width: 32, height: 32)
            Text("Sending — keep talking to add more")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .accessibilityLabel("Auto-sending your question in \(seconds) seconds. Keep talking to continue.")
    }
}

/// A single shimmering skeleton line (left-to-right sweep).
private struct AskShimmerLine: View {
    let widthFraction: CGFloat
    let animate: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var phase: CGFloat = -1

    var body: some View {
        let base = colorScheme == .dark ? Color.white.opacity(0.07) : Color(red: 40/255, green: 54/255, blue: 82/255).opacity(0.07)
        let hi = colorScheme == .dark ? Color.white.opacity(0.14) : Color(red: 40/255, green: 54/255, blue: 82/255).opacity(0.13)
        GeometryReader { geo in
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(base)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(colors: [.clear, hi, .clear], startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(width: geo.size.width * 0.5)
                        .offset(x: phase * geo.size.width)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .frame(height: 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .scaleEffect(x: widthFraction, anchor: .leading)
        .onAppear {
            guard animate else { return }
            phase = -1
            withAnimation(.linear(duration: 1.3).repeatForever(autoreverses: false)) {
                phase = 1.5
            }
        }
    }
}

/// Rotating, non-interactive spoken-aloud suggestions for the empty listening
/// hero. Phrased as things to *say*, set in SF Pro. Reuses the
/// app's shared `RotatingMessageView`.
private struct AskSuggestionLine: View {
    private static let suggestions = [
        "“Summarize what I recorded today”",
        "“What did I decide about the launch?”",
        "“Pull every note that mentions pricing”",
        "“What were my action items last week?”",
        "“Connect my notes about the redesign”",
    ]

    var body: some View {
        RotatingMessageView(
            messages: Self.suggestions,
            dwell: 2.8,
            sequenced: true,
            font: Font.system(size: 17, weight: .regular, design: .default),
            color: Color.jotPageInkCaption,
            alignment: .center,
            rise: 0
        )
        .accessibilityLabel("Examples of what you can ask, like summarizing your day or asking about a topic")
    }
}

/// Question header shared by thinking / answer / edge states — "YOU ASKED"
/// eyebrow + the question in SF Pro, with an optional right-aligned glass
/// pill (e.g. "Ask another" when done, "Cancel" while in flight).
private struct AskQuestionHeader: View {
    let question: String
    var trailingLabel: String? = nil
    var trailingAction: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("YOU ASKED")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.jotPageInkCaption)
                Text(question)
                    .font(.system(size: 22, weight: .regular, design: .default))
                    .tracking(-0.3)
                    .lineSpacing(2)
                    .foregroundStyle(Color.jotPageInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailingLabel, let trailingAction {
                Button(action: trailingAction) {
                    Text(trailingLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AskView.accentSolidPublic)
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .modifier(JotDesign.Surface.key.modifier(cornerRadius: 17))
                }
                .buttonStyle(.plain)
                .padding(.top, 14)
            }
        }
        .padding(.horizontal, 22)
    }
}

/// The single send-stop control. Dim/disabled until there are words; accent
/// gradient + glow when ready. Tapping both stops dictation and sends.
private struct AskSendStop: View {
    let ready: Bool
    let size: CGFloat
    let gradient: LinearGradient
    let glow: Color
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: { if ready { action() } }) {
            ZStack {
                Circle()
                    .fill(
                        ready
                            ? AnyShapeStyle(gradient)
                            : AnyShapeStyle(colorScheme == .dark ? Color.white.opacity(0.10) : Color(red: 40/255, green: 54/255, blue: 82/255).opacity(0.10))
                    )
                if ready {
                    Circle()
                        .stroke(Color.white.opacity(0.34), lineWidth: 0.5)
                        .blendMode(.plusLighter)
                }
                Image(systemName: "arrow.up")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(ready ? .white : (colorScheme == .dark ? Color.white.opacity(0.5) : Color(red: 40/255, green: 54/255, blue: 82/255).opacity(0.5)))
            }
            .frame(width: size, height: size)
            .shadow(color: ready ? glow : .clear, radius: 11, x: 0, y: 8)
        }
        .buttonStyle(.plain)
        .disabled(!ready)
        .animation(.easeInOut(duration: 0.3), value: ready)
    }
}

/// Inline citation chip — accent-soft pill with a doc glyph + label.
private struct AskCitationChip: View {
    let label: String
    let accent: Color
    let soft: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "doc.fill")
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.system(size: 12.5, weight: .semibold))
        }
        .foregroundStyle(accent)
        .padding(EdgeInsets(top: 1.5, leading: 5, bottom: 1.5, trailing: 7))
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(soft)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(accent.opacity(0.25), lineWidth: 0.5)
                )
        )
    }
}

/// Source row — rounded doc tile + date / snippet column + chevron.
private struct AskSourceRow: View {
    let date: String
    let snippet: String
    let accent: Color
    let soft: Color

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(soft)
                .frame(width: 30, height: 30)
                .overlay(
                    Image(systemName: "doc.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(accent)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(date)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Color.jotPageInk)
                Text(snippet)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.jotPageInkCaption)
        }
        .padding(.vertical, 11)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

/// Cycling thinking status — cross-fades through the steps on a gentle cadence.
/// Under Reduce Motion the simulated rotation is suppressed (the steps are a
/// cosmetic progress simulation, not true phase state) and a single neutral
/// "Thinking…" line is shown instead.
private struct AskThinkingStatus: View {
    let steps: [String]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var index = 0

    var body: some View {
        if reduceMotion {
            Text("Thinking…")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.jotPageInkSecondary)
        } else {
            Text(steps.indices.contains(index) ? steps[index] : (steps.first ?? ""))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.jotPageInkSecondary)
                .id(index)
                .transition(.opacity)
                .task(id: steps) {
                    index = min(index, max(0, steps.count - 1))
                    guard steps.count > 1 else { return }
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        if Task.isCancelled { return }
                        withAnimation(.easeInOut(duration: 0.4)) {
                            index = (index + 1) % steps.count
                        }
                    }
                }
        }
    }
}

// Expose the accent to the private header atom without re-declaring it.
extension AskView {
    static var accentSolidPublic: Color { accentInk }
}

// MARK: - FlowLayout

/// Wrapping HStack — lays out children left-to-right, wrapping to the next line
/// when the available width is exceeded. SwiftUI's stock `HStack` doesn't wrap.
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
#endif
