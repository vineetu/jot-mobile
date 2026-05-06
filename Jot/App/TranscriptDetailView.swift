import SwiftData
import SwiftUI
import UIKit
import os.log

private let detailLog = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "transcript-detail")

/// Push-detail surface for a single transcript row.
///
/// ## Apple-native pattern
///
/// Modelled after Voice Memos / Mail / Notes detail screens — a `NavigationLink`
/// destination, NOT a sheet or modal. Built for use inside the existing
/// `NavigationStack` in `ContentView` so the back chevron and large-title
/// transition come for free.
///
/// ## What's shown
///
/// - **Title bar**: first ~6 words of the transcript (or relative date if empty).
/// - **Body**: full text with `.textSelection(.enabled)` so users can grab
///   ranges. When `cleanedText` is present and differs from the raw `text`, both
///   are shown with a clear "Cleaned" / "Original" eyebrow split. Otherwise just
///   the single body block, no chrome.
/// - **Metadata**: relative date + word count.
/// - **Toolbar**: Magic (sparkles) trailing in nav bar to open the AI rewrite
///   menu. Copy + Delete in `.bottomBar`, matching Mail's destructive-action
///   placement. Delete confirmation dialog mirrors the in-list pattern in
///   `ContentView`.
///
/// ## AI rewrite UX (in-process)
///
/// Tapping the Magic affordance opens a `Menu` of `SavedPromptStore.all()`
/// rows. Selecting a row kicks off `LLMClientFactory.shared.client().rewrite`
/// in-process — no IPC, no URL bounce, no extension handoff. While the task
/// is in flight we show a proposed-result panel under the original with a
/// progress indicator + Cancel; on completion the user explicitly Applies
/// or Discards. Apply writes the rewrite to `cleanedText` (preserving the
/// raw `text`), Discard drops the proposal entirely. Cancel is silent.
/// Errors render inline below the proposal panel.
struct TranscriptDetailView: View {
    let transcript: Transcript

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var pendingDeletion = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var copyHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var errorMessage: String?

    // MARK: - AI rewrite state
    //
    // `rewriteState` is the single source of truth for the rewrite UI. The
    // detail view drives in-process: no AppGroup slots, no Darwin
    // notifications, no URL bounce. Cancellation propagates by holding the
    // `Task` and calling `.cancel()` — `Phi4Client.rewrite` honors
    // `Task.checkCancellation()` and `withTaskCancellationHandler`, so the
    // catch branch sees `CancellationError` and silently resets state.

    enum RewriteState: Equatable {
        case idle
        case running
        case proposing(String)        // result text, awaiting Apply / Discard
        case error(String)            // error message; user dismisses to clear
    }

    @State private var rewriteState: RewriteState = .idle
    @State private var activeRewriteTask: Task<Void, Never>?

    /// Saved prompts list, populated on appear. We poll on appearance only —
    /// settings can mutate the list, but the user is most likely to land here
    /// freshly each time, so re-reading on `.task` covers the common case
    /// without a 1Hz tick.
    @State private var savedPrompts: [SavedPrompt] = []

    /// Mirrors `LLMClientFactory.shared.client().status == .ready`. Refreshed
    /// on appear and again when the user taps the Magic menu (cheap to read).
    /// Drives the disabled-state of the Magic button alongside
    /// `AppGroup.aiRewriteEnabled`.
    @State private var isLLMReady = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                metadataRow

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }

                bodyContent

                rewriteSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                magicMenu
            }

            ToolbarItem(placement: .bottomBar) {
                Button {
                    copy()
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(didCopy ? "Copied to clipboard" : "Copy transcript")
            }

            ToolbarItem(placement: .bottomBar) {
                Spacer()
            }

            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    pendingDeletion = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityLabel("Delete transcript")
            }
        }
        .confirmationDialog(
            "Delete this entry?",
            isPresented: $pendingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                delete()
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = false
            }
        }
        .onAppear {
            copyHaptic.prepare()
            refreshRewriteAvailability()
        }
        .onDisappear {
            copyResetTask?.cancel()
            // Cancel any in-flight rewrite when the user navigates away. The
            // result would have nowhere to land — the bound `transcript`
            // reference may still be valid (no delete), but the user
            // signalled they're done with this surface, so the silent
            // cancel is the right call.
            activeRewriteTask?.cancel()
            activeRewriteTask = nil
        }
        .task {
            // `.task` re-runs after every navigation appearance and is a
            // natural fit for "load the prompts list + probe model status".
            refreshRewriteAvailability()
        }
    }

    // MARK: - Subviews

    private var metadataRow: some View {
        HStack(spacing: 6) {
            Text(relativeDateText)
            Text("·")
            Text(wordCountText)
            if let durationText {
                Text("·")
                Text(durationText)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var bodyContent: some View {
        if let cleaned = transcript.cleanedText, cleaned != transcript.text, !cleaned.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                section(label: "Cleaned", text: cleaned)
                section(label: "Original", text: transcript.text)
            }
        } else {
            Text(transcript.displayText)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Magic affordance in the nav bar trailing slot. Two visual states:
    /// `Menu` of saved prompts (idle) and a Cancel button (running). The
    /// menu disables itself when AI rewrite is off, the model isn't ready,
    /// or there are no saved prompts to pick from.
    @ViewBuilder
    private var magicMenu: some View {
        switch rewriteState {
        case .running:
            Button(role: .cancel) {
                cancelActiveRewrite()
            } label: {
                Label("Cancel", systemImage: "xmark")
            }
            .accessibilityLabel("Cancel rewrite")

        case .idle, .proposing, .error:
            Menu {
                ForEach(savedPrompts) { prompt in
                    Button {
                        startRewrite(with: prompt)
                    } label: {
                        Label(prompt.name, systemImage: "sparkles")
                    }
                }
            } label: {
                Image(systemName: "sparkles")
            }
            .menuOrder(.fixed)
            .disabled(!isMagicEnabled)
            .accessibilityLabel(magicAccessibilityLabel)
            .accessibilityHint(isMagicEnabled ? "Opens AI rewrite menu" : "")
        }
    }

    /// Proposed-rewrite panel. Renders below the transcript body when a
    /// rewrite is in flight or when a result is awaiting accept/reject.
    /// Idle state is `EmptyView` so the surface stays uncluttered at rest.
    @ViewBuilder
    private var rewriteSection: some View {
        switch rewriteState {
        case .idle:
            EmptyView()

        case .running:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Rewriting…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        cancelActiveRewrite()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Cancel rewrite")
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .accessibilityElement(children: .combine)

        case .proposing(let result):
            VStack(alignment: .leading, spacing: 12) {
                Text("Rewrite")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)

                Text(result)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Button(role: .cancel) {
                        discardProposal()
                    } label: {
                        Label("Discard", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Spacer(minLength: 0)

                    Button {
                        applyProposal(result: result)
                    } label: {
                        Label("Apply", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )

        case .error(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    rewriteState = .idle
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss error")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .systemOrange).opacity(0.12))
            )
        }
    }

    // MARK: - Magic gate

    private var isMagicEnabled: Bool {
        AppGroup.aiRewriteEnabled
            && isLLMReady
            && !savedPrompts.isEmpty
    }

    private var magicAccessibilityLabel: String {
        if isMagicEnabled { return "AI rewrite" }
        if !AppGroup.aiRewriteEnabled {
            return "AI rewrite, disabled — turn on AI rewrite in Settings"
        }
        if !isLLMReady {
            return "AI rewrite, unavailable — model is not ready"
        }
        if savedPrompts.isEmpty {
            return "AI rewrite, disabled — no saved prompts"
        }
        return "AI rewrite"
    }

    // MARK: - Derived strings

    private var navigationTitle: String {
        let trimmed = transcript.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return transcript.createdAt.formatted(date: .abbreviated, time: .shortened)
        }
        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(6)
            .joined(separator: " ")
        return words
    }

    private var relativeDateText: String {
        transcript.createdAt.formatted(.relative(presentation: .named))
    }

    private var wordCountText: String {
        let count = transcript.displayText
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .count
        return count == 1 ? "1 word" : "\(count) words"
    }

    private var durationText: String? {
        guard let duration = transcript.durationSeconds else { return nil }
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Actions

    private func copy() {
        UIPasteboard.general.string = transcript.displayText
        copyHaptic.impactOccurred()
        copyHaptic.prepare()
        UIAccessibility.post(notification: .announcement, argument: "Copied to clipboard")

        didCopy = true
        copyResetTask?.cancel()
        copyResetTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(1_300))
            } catch {
                return
            }
            didCopy = false
        }
    }

    private func delete() {
        // Dismiss FIRST to pop this view off the stack before SwiftData
        // tombstones the bound `transcript` reference. If we deleted first,
        // any `@State` mutation on this turn (or a parent `@Query`
        // invalidation) could trigger a body re-render that reads
        // `transcript.text` on a deleted managed object → crash. Per the
        // SwiftData detail-view pattern. The `Task` defers the actual
        // delete to the next MainActor turn, after the pop animation has
        // taken this view's body out of the render tree.
        // Cancel any in-flight rewrite first — the bound managed object is
        // about to be tombstoned, and we don't want the result handler to
        // touch `transcript.cleanedText` on a deleted row.
        activeRewriteTask?.cancel()
        activeRewriteTask = nil

        dismiss()
        Task { @MainActor in
            modelContext.delete(transcript)
            do {
                try modelContext.save()
                TranscriptHistoryMirror.refresh(from: modelContext)
            } catch {
                modelContext.rollback()
                detailLog.error("Transcript delete save failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Rewrite lifecycle

    /// Pulls the latest prompts list and probes the LLM client status.
    /// Called on appear and on each `.task` re-run. Cheap — both reads are
    /// in-process, no IO blocking.
    private func refreshRewriteAvailability() {
        savedPrompts = SavedPromptStore.all()
        // Probe client status. `LLMClientFactory.shared.client().status` is
        // `async` because backends like Phi-4 use actor isolation; we kick a
        // tiny Task to read it and update `isLLMReady`. The Magic affordance
        // appears disabled until the probe completes — the first frame's
        // `isLLMReady = false` is the safest default.
        let aiOn = AppGroup.aiRewriteEnabled
        guard aiOn else {
            isLLMReady = false
            return
        }
        Task { @MainActor in
            let status = await LLMClientFactory.shared.client().status
            isLLMReady = (status == .ready)
        }
    }

    /// Kicks off an in-process rewrite for the given prompt. Holds the Task
    /// in `activeRewriteTask` so the Cancel affordance can call `.cancel()`.
    /// The Task body is `MainActor`-isolated because the LLM clients hop to
    /// their internal actors / `@MainActor` discipline; the rewrite runs on
    /// background queues per the client's own setup.
    private func startRewrite(with prompt: SavedPrompt) {
        let source = transcript.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else {
            rewriteState = .error("Transcript is empty.")
            return
        }
        guard isMagicEnabled else { return }

        // Cancel any prior in-flight task before starting a new one.
        activeRewriteTask?.cancel()
        rewriteState = .running

        let promptText = prompt.systemPrompt
        let task = Task { @MainActor in
            do {
                let result = try await LLMClientFactory.shared.client().rewrite(
                    text: source,
                    systemPrompt: promptText
                )
                try Task.checkCancellation()
                let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    rewriteState = .error("Rewrite returned no text.")
                    return
                }
                rewriteState = .proposing(trimmed)
                detailLog.info(
                    "Transcript rewrite SUCCESS prompt=\(prompt.id, privacy: .public) inputChars=\(source.count) outputChars=\(trimmed.count)"
                )
            } catch is CancellationError {
                // User-initiated cancel — silent reset.
                rewriteState = .idle
                detailLog.info("Transcript rewrite cancelled prompt=\(prompt.id, privacy: .public)")
            } catch {
                rewriteState = .error(error.localizedDescription)
                detailLog.error(
                    "Transcript rewrite FAILED prompt=\(prompt.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            }
        }
        activeRewriteTask = task
    }

    private func cancelActiveRewrite() {
        activeRewriteTask?.cancel()
        activeRewriteTask = nil
        // The Task's `catch is CancellationError` branch flips state back to
        // `.idle`; setting it here too keeps the UI snappy if the catch
        // branch hasn't run yet.
        if case .running = rewriteState {
            rewriteState = .idle
        }
    }

    private func discardProposal() {
        rewriteState = .idle
    }

    /// Persists the rewrite to `cleanedText`, preserving the raw `text`.
    /// `displayText` already prefers `cleanedText`, so the body switches to
    /// the rewritten version with no further wiring. The `cleanedText`
    /// surface is the existing "post-cleanup output" slot — overloading it
    /// for AI rewrites here is consistent with the model's intent ("LLM-
    /// rewritten variant"; see `Transcript.swift`).
    private func applyProposal(result: String) {
        transcript.cleanedText = result
        do {
            try modelContext.save()
            TranscriptHistoryMirror.refresh(from: modelContext)
            rewriteState = .idle
            detailLog.info("Transcript rewrite applied — cleanedText updated")
        } catch {
            modelContext.rollback()
            rewriteState = .error("Couldn't save: \(error.localizedDescription)")
            detailLog.error(
                "Transcript rewrite save failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

#Preview {
    NavigationStack {
        TranscriptDetailView(
            transcript: Transcript(
                text: "This is the raw transcript that came straight out of Parakeet without any cleanup applied.",
                cleanedText: "This is the cleaned transcript with light edits applied.",
                ledgerIndex: 42
            )
        )
    }
    .modelContainer(for: Transcript.self, inMemory: true)
}
