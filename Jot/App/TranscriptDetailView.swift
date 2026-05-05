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
/// - **Toolbar**: Copy + Delete in `.bottomBar`, matching Mail's destructive-action
///   placement. Delete confirmation dialog mirrors the in-list pattern in
///   `ContentView`.
///
/// ## Lifecycle on delete
///
/// After a successful `modelContext.delete` we `dismiss()` back to the list — the
/// `@Query` in `ContentView` reactively drops the row. We refresh the
/// `TranscriptHistoryMirror` to keep the keyboard-extension snapshot in sync,
/// matching the behavior in `ContentView.delete(_:)`.
struct TranscriptDetailView: View {
    let transcript: Transcript

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var pendingDeletion = false
    @State private var didCopy = false
    @State private var copyResetTask: Task<Void, Never>?
    @State private var copyHaptic = UIImpactFeedbackGenerator(style: .light)
    @State private var errorMessage: String?

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
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
        }
        .onDisappear {
            copyResetTask?.cancel()
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
