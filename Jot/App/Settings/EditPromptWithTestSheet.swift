import SwiftUI
import SwiftData

/// Phase 5 — Edit prompt with test panel (mockup 19).
///
/// Bottom sheet drawer (~660pt / `.large` detent) that shows the prompt
/// header, the system-prompt text in a glass card, and a coral-bordered
/// "TEST ON A RECORDING" card. The user can pick any transcript from the
/// SwiftData store via `Test on · <title>`, then tap "Run again" to fire
/// `LLMClient.rewrite(text:systemPrompt:)`. Original (italic mono) +
/// rewritten (Fraunces 13pt) outputs stack vertically. Per plan §14.7 the
/// run shows a simple spinner — no louder banner.
///
/// "Expand editor →" pushes a full-screen plain text editor for the system
/// prompt. The full-screen editor edits the in-flight draft; Save on the
/// header commits the draft back to `SavedPromptStore`.
///
/// The seeded `defaultRewrite` / `defaultBulletPoints` rows are fully
/// editable here — when the user saves their edits, the stable UUID is
/// preserved so existing references keep resolving.
struct EditPromptWithTestSheet: View {
    let prompt: SavedPrompt?
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Draft state

    @State private var name: String = ""
    @State private var systemPrompt: String = ""
    @State private var showFullScreenEditor: Bool = false

    // MARK: - Test panel state

    @State private var testTranscriptID: UUID?
    @State private var testTranscriptTitle: String = "Pick a recording"
    @State private var testOriginalText: String = ""
    @State private var testRewrittenText: String = ""
    @State private var isRunningTest: Bool = false
    @State private var testErrorMessage: String?
    @State private var showTranscriptPicker: Bool = false

    private var isEditing: Bool { prompt != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSystemPrompt: String { systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedSystemPrompt.isEmpty }

    private var headerIconSymbol: String {
        // Seeded prompts get purpose-specific icons; user-created prompts
        // get the generic purple list bullet (same as the AI Settings list).
        if prompt?.id == SavedPrompt.defaultBulletPoints.id {
            return "list.bullet"
        }
        return "wand.and.stars"
    }

    private var headerIconTint: Color {
        prompt?.id == SavedPrompt.defaultBulletPoints.id ? Color.purple : Color.jotAccent
    }

    private var headerSubline: String? {
        guard let prompt else { return nil }
        if prompt.id == SavedPrompt.defaultRewrite.id { return "Default prompt" }
        if prompt.id == SavedPrompt.defaultBulletPoints.id { return "Default prompt" }
        return nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                JotDesign.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGap) {
                        promptHeaderRow

                        systemPromptSection

                        testSection
                    }
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.vertical, 16)
                }
            }
            .navigationTitle(displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityLabel("Cancel editing")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .tint(.jotAccent)
                    .disabled(!canSave)
                    .accessibilityLabel("Save prompt")
                }
            }
            .navigationDestination(isPresented: $showFullScreenEditor) {
                ExpandedSystemPromptEditor(text: $systemPrompt)
            }
            .sheet(isPresented: $showTranscriptPicker) {
                TranscriptPickerSheet { transcript in
                    selectTranscript(transcript)
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .onAppear {
                if let existing = prompt {
                    name = existing.name
                    systemPrompt = existing.systemPrompt
                }
                loadMostRecentTranscriptIfNeeded()
            }
        }
    }

    private var displayTitle: String {
        if let prompt {
            return prompt.name
        }
        return "New prompt"
    }

    // MARK: - Header row

    private var promptHeaderRow: some View {
        GlassCard(tier: .regular, padding: 14) {
            HStack(spacing: 12) {
                IconBox(symbol: headerIconSymbol, tint: headerIconTint, size: 40)

                VStack(alignment: .leading, spacing: 3) {
                    TextField("Prompt name", text: $name)
                        .font(.custom(JotType.frauncesSemiBold, size: 16))
                        .foregroundStyle(Color.jotInk)
                        .textInputAutocapitalization(.words)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > SavedPrompt.nameMaxLength {
                                name = String(newValue.prefix(SavedPrompt.nameMaxLength))
                            }
                        }

                    if let sub = headerSubline {
                        Text(sub)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.jotMute)
                    }
                }
                Spacer()
            }
        }
    }

    // MARK: - System prompt

    private var systemPromptSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("SYSTEM PROMPT")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    ZStack(alignment: .bottom) {
                        ScrollView(.vertical, showsIndicators: false) {
                            Text(displayedSystemPrompt)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.jotInk)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                        }
                        .frame(maxHeight: 130)

                        // Bottom fade to suggest "more text" before the
                        // Expand-editor affordance. Top stop is `.clear`
                        // (transparent) and the bottom stop blends into
                        // the card surface so the bottom of the visible
                        // text appears to fade out before the link.
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.white.opacity(0.7)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 24)
                        .allowsHitTesting(false)
                    }

                    Button {
                        showFullScreenEditor = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("Expand editor")
                                .font(.system(size: 14, weight: .semibold))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.jotAccent)
                        .frame(minHeight: 44, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Expand editor")
                    .accessibilityHint("Opens the full-screen system prompt editor")
                }
            }
        }
    }

    private var displayedSystemPrompt: String {
        if trimmedSystemPrompt.isEmpty {
            return "Instruction for the rewrite model…"
        }
        return systemPrompt
    }

    // MARK: - Test on a recording

    private var testSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("TEST ON A RECORDING")
                .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 14) {
                // Recording picker row
                Button {
                    showTranscriptPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Text("Test on")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.jotMute)
                        Text("·")
                            .foregroundStyle(Color.jotMute)
                        Text(testTranscriptTitle)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color.jotInk)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        RowChevron()
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Test on \(testTranscriptTitle)")
                .accessibilityHint("Picks a recording to test the prompt on")

                if !testOriginalText.isEmpty {
                    Divider().opacity(0.4)

                    Text(testOriginalText)
                        .font(.system(size: 14, design: .monospaced).italic())
                        .foregroundStyle(Color.jotMute)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(8)

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.jotAccent)
                        Text("Rewrite")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.jotAccent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if isRunningTest {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Running…")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.jotMute)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let err = testErrorMessage {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if !testRewrittenText.isEmpty {
                        Text(testRewrittenText)
                            .font(.custom(JotType.frauncesRegular, size: 13))
                            .foregroundStyle(Color.jotInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(12)
                    } else {
                        Text("Tap Run again to rewrite this transcript with the current prompt.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.jotMute)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider().opacity(0.4)

                    HStack(spacing: 12) {
                        Text(JotDesign.activeRewriteModelDisplayName)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.jotMute)

                        Spacer()

                        Button {
                            runTest()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Run again")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Color.jotAccent)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(isRunningTest || testTranscriptID == nil || trimmedSystemPrompt.isEmpty)
                        .accessibilityLabel("Run rewrite again")

                        Button {
                            copyRewritten()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 12, weight: .semibold))
                                Text("Copy")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .foregroundStyle(Color.jotAccent)
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(testRewrittenText.isEmpty)
                        .accessibilityLabel("Copy rewritten text")
                    }
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .strokeBorder(Color.jotAccent.opacity(0.55), lineWidth: 1)
            )
            .shadow(color: Color.jotAccent.opacity(0.10), radius: 6, x: 0, y: 4)
        }
    }

    // MARK: - Actions

    private func saveAndDismiss() {
        guard canSave else { return }
        if let existing = prompt {
            // Preserve stable UUID — including for the seeded defaults so
            // existing references in the rewrite picker keep resolving.
            let updated = SavedPrompt(
                id: existing.id,
                name: trimmedName,
                systemPrompt: trimmedSystemPrompt,
                createdAt: existing.createdAt,
                sortOrder: existing.sortOrder
            )
            SavedPromptStore.update(updated)
        } else {
            let new = SavedPrompt(
                id: UUID(),
                name: trimmedName,
                systemPrompt: trimmedSystemPrompt,
                createdAt: Date(),
                sortOrder: 0 // overridden by the store to "after current last"
            )
            SavedPromptStore.add(new)
        }
        onChange()
        dismiss()
    }

    private func selectTranscript(_ snapshot: TranscriptSnapshot) {
        testTranscriptID = snapshot.id
        testTranscriptTitle = snapshot.title
        testOriginalText = snapshot.text
        testRewrittenText = ""
        testErrorMessage = nil
        showTranscriptPicker = false
    }

    private func loadMostRecentTranscriptIfNeeded() {
        guard testTranscriptID == nil else { return }
        // Pre-fill with the most recent transcript so "Run again" works
        // immediately without forcing the user to drill into the picker.
        if let snapshot = TranscriptPickerSheet.mostRecent() {
            selectTranscript(snapshot)
        }
    }

    private func runTest() {
        guard !trimmedSystemPrompt.isEmpty, !testOriginalText.isEmpty else { return }
        isRunningTest = true
        testErrorMessage = nil
        testRewrittenText = ""

        let textToRewrite = testOriginalText
        let systemInstruction = trimmedSystemPrompt
        Task { @MainActor in
            let client = LLMClientFactory.shared.client()
            do {
                let output = try await client.rewrite(text: textToRewrite, systemPrompt: systemInstruction)
                testRewrittenText = output
            } catch {
                testErrorMessage = "Rewrite failed — \(error.localizedDescription)"
            }
            isRunningTest = false
        }
    }

    private func copyRewritten() {
        guard !testRewrittenText.isEmpty else { return }
        #if canImport(UIKit)
        UIPasteboard.general.string = testRewrittenText
        #endif
    }
}

// MARK: - Full-screen system prompt editor

/// Pushed onto the nav stack when the user taps "Expand editor →". A simple
/// `TextEditor` bound to the parent's `systemPrompt` draft state so edits
/// flow back automatically.
private struct ExpandedSystemPromptEditor: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .focused($isEditorFocused)
            .navigationTitle("System prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .accessibilityLabel("Close editor")
                }
            }
            .onAppear { isEditorFocused = true }
            .onChange(of: text) { _, newValue in
                if newValue.count > SavedPrompt.systemPromptMaxLength {
                    text = String(newValue.prefix(SavedPrompt.systemPromptMaxLength))
                }
            }
    }
}

// MARK: - Transcript picker sheet

/// Lightweight value snapshot of a `Transcript` row. The full SwiftData
/// model is bound to a short-lived context — we can't safely cross actor
/// boundaries with it, so we snapshot the fields we need at fetch time.
struct TranscriptSnapshot: Identifiable, Hashable {
    let id: UUID
    let title: String
    let text: String
    let createdAt: Date
}

/// Sheet that lists recent transcripts. Tapping a row hands the snapshot
/// back to the caller. Read-only — does not mutate the SwiftData store.
private struct TranscriptPickerSheet: View {
    let onPick: (TranscriptSnapshot) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var snapshots: [TranscriptSnapshot] = []

    var body: some View {
        NavigationStack {
            List {
                if snapshots.isEmpty {
                    Text("No recordings yet. Dictate something to test the prompt.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                } else {
                    ForEach(snapshots) { snapshot in
                        Button {
                            onPick(snapshot)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(snapshot.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundStyle(Color.jotInk)
                                    .lineLimit(1)
                                Text(snapshot.text)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.jotMute)
                                    .lineLimit(2)
                            }
                            .frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Pick a recording")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                snapshots = Self.recent(limit: 50)
            }
        }
    }

    // MARK: - Static fetch helpers

    /// Returns the most-recently-created transcript as a snapshot, or
    /// `nil` if the store is empty.
    static func mostRecent() -> TranscriptSnapshot? {
        recent(limit: 1).first
    }

    /// Reads the top `limit` transcripts from SwiftData, newest first,
    /// and returns them as immutable snapshots.
    @MainActor
    static func recent(limit: Int) -> [TranscriptSnapshot] {
        let context = ModelContext(JotModelContainer.shared)
        var descriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let rows = (try? context.fetch(descriptor)) ?? []
        return rows.map { row in
            TranscriptSnapshot(
                id: row.id,
                title: snapshotTitle(for: row),
                text: row.displayText,
                createdAt: row.createdAt
            )
        }
    }

    private static func snapshotTitle(for row: Transcript) -> String {
        // Derive a short title from the first sentence / first 48 chars of
        // the transcript. The SwiftData schema doesn't carry a separate
        // title field today (per plan §14.4 the serif title slot is hidden
        // in v1), so we approximate.
        let text = row.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "Recording #\(row.ledgerIndex)"
        }
        let firstLine = text.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? text
        if firstLine.count <= 48 { return firstLine }
        let prefix = firstLine.prefix(45)
        return "\(prefix)…"
    }
}

#Preview("Edit") {
    EditPromptWithTestSheet(prompt: SavedPrompt.defaultRewrite, onChange: {})
}

#Preview("New") {
    EditPromptWithTestSheet(prompt: nil, onChange: {})
}
