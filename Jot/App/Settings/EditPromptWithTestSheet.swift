import SwiftUI
import SwiftData

/// Phase 5 (v0.9 redesign) — Edit prompt with inline Try-this-prompt panel.
///
/// Bottom sheet drawer (`.large` detent) that lets the user edit an existing
/// saved prompt or compose a new one (the New-prompt path is owned by
/// `NewPromptSheet`; this sheet handles editing only). The system-prompt is
/// the hero — a full-bleed mono editor with a coral blinking caret. The
/// previous "Test on a recording" card is replaced by a slim "Try this prompt"
/// footer pill that expands into a coral-bordered result panel after Run.
///
/// Behavioral surface preserved from the previous implementation:
///   - `saveAndDismiss` / `selectTranscript` / `loadMostRecentTranscriptIfNeeded`
///     / `runTest` / `copyRewritten` are untouched.
///   - `TranscriptSnapshot` + `TranscriptPickerSheet` + `ExpandedSystemPromptEditor`
///     are kept at the bottom of the file.
///   - Stable UUID is preserved on save so existing keyboard/picker references
///     keep resolving.
struct EditPromptWithTestSheet: View {
    let prompt: SavedPrompt?
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    // MARK: - Draft state

    @State private var name: String = ""
    @State private var systemPrompt: String = ""
    @State private var showFullScreenEditor: Bool = false
    @State private var cursorVisible: Bool = true

    // MARK: - Test panel state

    @State private var testTranscriptID: UUID?
    @State private var testTranscriptTitle: String = "Pick a recording"
    @State private var testOriginalText: String = ""
    @State private var testRewrittenText: String = ""
    @State private var isRunningTest: Bool = false
    @State private var testErrorMessage: String?
    @State private var elapsedSeconds: Double = 0
    @State private var showTranscriptPicker: Bool = false

    private var isEditing: Bool { prompt != nil }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSystemPrompt: String { systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedSystemPrompt.isEmpty }

    private var headerIconSymbol: String {
        switch prompt?.defaultKind {
        case .articulate:  return "wand.and.stars"
        case .actionItems: return "checklist"
        case .email:       return "envelope"
        case nil:          return "wand.and.stars"
        }
    }

    private var headerIconTint: Color {
        switch prompt?.defaultKind {
        case .articulate:  return JotDesign.JotSemanticIcon.ai
        case .actionItems: return AIV09Tokens.purple
        case .email:       return Color.jotSuccess
        case nil:          return JotDesign.JotSemanticIcon.ai
        }
    }

    private var headerIconShaded: Color {
        switch prompt?.defaultKind {
        case .articulate:  return JotDesign.JotSemanticIcon.aiShaded
        case .actionItems: return AIV09Tokens.purpleShaded
        case .email:       return Color.jotSuccess.opacity(0.5)
        case nil:          return JotDesign.JotSemanticIcon.aiShaded
        }
    }

    private var headerSubline: String? {
        prompt?.defaultKind != nil ? "Default prompt" : nil
    }

    private var displayTitle: String {
        if let prompt {
            return prompt.name
        }
        return "New prompt"
    }

    private var hasResultState: Bool {
        !testRewrittenText.isEmpty || testErrorMessage != nil || isRunningTest
    }

    private var slimPreviewText: String {
        guard !testOriginalText.isEmpty else {
            return "Pick a recording to try this prompt."
        }
        let trimmed = testOriginalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.prefix(40)
        return "on \(testTranscriptTitle) — \u{201C}\(prefix)…\u{201D}"
    }

    var body: some View {
        ZStack {
            WallpaperBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                dragHandle
                headerRow
                    .padding(.horizontal, 18)
                    .padding(.bottom, 12)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        promptHeaderCard
                        systemPromptEditorCard

                        if hasResultState {
                            tryResultPanel
                        } else {
                            slimTryPill
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
        .sheet(isPresented: $showFullScreenEditor) {
            NavigationStack {
                ExpandedSystemPromptEditor(text: $systemPrompt)
            }
        }
        .sheet(isPresented: $showTranscriptPicker) {
            TranscriptPickerSheet(currentSelectionID: testTranscriptID) { transcript in
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
            startCursorBlink()
        }
    }

    // MARK: - Chrome

    private var dragHandle: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Color.jotPageInkSecondary.opacity(0.30))
            .frame(width: 36, height: 5)
            .padding(.vertical, 8)
            .accessibilityHidden(true)
    }

    private var headerRow: some View {
        HStack(alignment: .center) {
            Button {
                dismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotPageInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule(style: .continuous))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.jotPageInk.opacity(0.06), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel editing")

            Spacer()

            Text(displayTitle)
                .font(.system(size: 17, weight: .semibold))
                .tracking(-0.3)
                .foregroundStyle(Color.jotPageInk)
                .lineLimit(1)
                .layoutPriority(1)

            Spacer()

            CompactCoralPill(label: "Save", isEnabled: canSave) {
                saveAndDismiss()
            }
        }
    }

    // MARK: - Prompt header card

    private var promptHeaderCard: some View {
        LiquidGlassCard(paddingH: 16, paddingV: 14) {
            HStack(spacing: 12) {
                IconTile(
                    systemImage: headerIconSymbol,
                    tint: headerIconTint,
                    shaded: headerIconShaded,
                    size: 40
                )

                VStack(alignment: .leading, spacing: 3) {
                    TextField("Prompt name", text: $name)
                        .font(.system(size: 19, weight: .medium, design: .serif))
                        .foregroundStyle(Color.jotPageInk)
                        .textInputAutocapitalization(.words)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > SavedPrompt.nameMaxLength {
                                name = String(newValue.prefix(SavedPrompt.nameMaxLength))
                            }
                        }

                    if let sub = headerSubline {
                        Text(sub)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.jotPageInkSecondary)
                    }
                }

                Spacer()
            }
        }
    }

    // MARK: - System prompt editor

    private var systemPromptEditorCard: some View {
        LiquidGlassCard(cornerRadius: 18, paddingH: 0, paddingV: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("System prompt")
                        .font(JotType.sectionLabel)
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.jotPageInkCaption)

                    Spacer()

                    HStack(spacing: 6) {
                        BlinkingCaret(visible: cursorVisible)
                            .frame(width: 2, height: 14)

                        Text("\(systemPrompt.count) chars")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.jotPageInkSecondary)

                        Text("·")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.jotPageInkSecondary.opacity(0.5))

                        Button {
                            showFullScreenEditor = true
                        } label: {
                            Text("Expand")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.jotCoralTop)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Expand editor")
                        .accessibilityHint("Opens the full-screen system prompt editor")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .background(Color.jotPageInkCaption.opacity(0.20))

                TextEditor(text: $systemPrompt)
                    .font(JotType.monoEditor)
                    .lineSpacing(1.6)
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Color.jotPageInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(minHeight: 220)
                    .onChange(of: systemPrompt) { _, newValue in
                        if newValue.count > SavedPrompt.systemPromptMaxLength {
                            systemPrompt = String(newValue.prefix(SavedPrompt.systemPromptMaxLength))
                        }
                    }
                    .accessibilityLabel("System prompt editor")
            }
        }
    }

    // MARK: - Try this prompt (slim pill + expanded result panel)

    private var slimTryPill: some View {
        LiquidGlassCard(cornerRadius: 16, paddingH: 14, paddingV: 12) {
            HStack(spacing: 10) {
                Button {
                    showTranscriptPicker = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.jotCoralTop)

                        VStack(alignment: .leading, spacing: 1) {
                            Text("Try this prompt")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.jotPageInk)
                            HStack(spacing: 4) {
                                Text(slimPreviewText)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.jotPageInk)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.jotPageInkSecondary)
                                    .fixedSize()
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .buttonStyle(.plain)
                .accessibilityLabel("Pick a recording to test on")
                .accessibilityHint("Opens a list of recent recordings")

                CompactCoralPill(
                    label: "Run",
                    isEnabled: !trimmedSystemPrompt.isEmpty && !testOriginalText.isEmpty
                ) {
                    runTest()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var tryResultPanel: some View {
        let outerShape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 0) {
            // Header strip
            HStack(spacing: 8) {
                Text("Try this prompt")
                    .font(.system(size: 10.5, weight: .bold))
                    .tracking(1.5)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.jotCoralTop)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.jotPageInkSecondary.opacity(0.6))
                Text(testTranscriptTitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                Button {
                    dismissResultPanel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss result panel")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider().background(Color.jotPageInkCaption.opacity(0.20))

            // Body
            VStack(alignment: .leading, spacing: 12) {
                resultBeforeBlock
                resultArrowRow
                resultAfterBlock
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider().background(Color.jotPageInkCaption.opacity(0.20))

            // Footer
            HStack(spacing: 10) {
                Text(JotDesign.activeRewriteModelDisplayName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                resultActionPills
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .background(.regularMaterial, in: outerShape)
        .overlay(outerShape.strokeBorder(Color.jotCoralTop.opacity(0.45), lineWidth: 1))
        .clipShape(outerShape)
        .shadow(color: Color.jotCoralTop.opacity(0.20), radius: 20, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }

    private var resultBeforeBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Before")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.jotPageInkCaption)
            Text("\u{201C}\(testOriginalText)\u{201D}")
                .font(.system(size: 14).italic())
                .lineSpacing(2)
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var resultArrowRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Color.jotCoralTop)
            Text("Rewrite")
                .font(.system(size: 10.5, weight: .bold))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.jotCoralTop)
            Rectangle()
                .fill(Color.jotCoralTop.opacity(0.18))
                .frame(height: 1)
            if !isRunningTest, testErrorMessage == nil, !testRewrittenText.isEmpty {
                Text(String(format: "%.1fs", elapsedSeconds))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
        }
    }

    @ViewBuilder
    private var resultAfterBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("After")
                .font(.system(size: 10, weight: .bold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.jotPageInkCaption)

            if isRunningTest {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotPageInkSecondary)
                }
            } else if let err = testErrorMessage {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("\u{201C}\(testRewrittenText)\u{201D}")
                    .font(.system(size: 15, weight: .regular, design: .serif).italic())
                    .foregroundStyle(Color.jotPageInk)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var resultActionPills: some View {
        // Both pills are wrapped in fixedSize via parent so they never wrap.
        HStack(spacing: 8) {
            Button {
                copyRewritten()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Copy")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(Color.jotPageInk)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.jotPageInk.opacity(0.06), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .disabled(testRewrittenText.isEmpty)
            .accessibilityLabel("Copy rewritten text")

            Button {
                runTest()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Run again")
                        .font(.system(size: 12.5, weight: .semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.jotCoralTop, .jotCoralBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .shadow(color: Color.jotCoralTop.opacity(0.40), radius: 8, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(isRunningTest || trimmedSystemPrompt.isEmpty || testOriginalText.isEmpty)
            .accessibilityLabel("Run rewrite again")
        }
    }

    private func dismissResultPanel() {
        testRewrittenText = ""
        testErrorMessage = nil
        // Leaves testOriginalText / testTranscriptID intact so the next
        // Run still has a transcript to work with.
    }

    // MARK: - Cursor blink

    private func startCursorBlink() {
        // 0.5s on/off — gives the spec's 1s full cycle.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                cursorVisible.toggle()
            }
        }
    }

    // MARK: - Actions (preserved)

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
        if let snapshot = TranscriptPickerSheet.mostRecent() {
            selectTranscript(snapshot)
        }
    }

    private func runTest() {
        guard !trimmedSystemPrompt.isEmpty, !testOriginalText.isEmpty else { return }
        isRunningTest = true
        testErrorMessage = nil
        testRewrittenText = ""
        elapsedSeconds = 0

        let textToRewrite = testOriginalText
        let systemInstruction = trimmedSystemPrompt
        let startDate = Date()
        Task { @MainActor in
            let client = LLMClientFactory.shared.client()
            do {
                let output = try await client.rewrite(text: textToRewrite, systemPrompt: systemInstruction)
                testRewrittenText = output
            } catch {
                testErrorMessage = "Rewrite failed — \(error.localizedDescription)"
            }
            elapsedSeconds = Date().timeIntervalSince(startDate)
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

// MARK: - Local helper views

/// Compact coral CTA pill used inside the sheet header (Save) and the
/// slim Try-this-prompt footer (Run). Smaller than the full
/// `CoralActionButton` so it fits in 36-40pt-tall chrome rows.
struct CompactCoralPill: View {
    let label: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.jotCoralTop, .jotCoralBottom],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .opacity(isEnabled ? 1 : 0.45)
                )
                .shadow(color: Color.jotCoralTop.opacity(isEnabled ? 0.40 : 0), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(Text(label))
    }
}

/// 2x14 blinking coral caret used in the editor toolbar to telegraph an
/// active editing surface. Decorative — the real iOS caret renders
/// naturally inside the TextEditor.
struct BlinkingCaret: View {
    let visible: Bool

    var body: some View {
        Rectangle()
            .fill(Color.jotCoralTop)
            .opacity(visible ? 1 : 0)
            .animation(.linear(duration: 0.15), value: visible)
            .accessibilityHidden(true)
    }
}

// MARK: - Full-screen system prompt editor

/// Pushed via sheet when the user taps "Expand". A simple `TextEditor` bound
/// to the parent's `systemPrompt` draft state so edits flow back automatically.
private struct ExpandedSystemPromptEditor: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(JotType.monoEditor)
            .lineSpacing(1.6)
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
    let currentSelectionID: UUID?
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
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(snapshot.title)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(Color.jotPageInk)
                                        .lineLimit(1)
                                    Text(snapshot.text)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.jotPageInkSecondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                if snapshot.id == currentSelectionID {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.jotCoralTop)
                                        .accessibilityHidden(true)
                                }
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

    static func mostRecent() -> TranscriptSnapshot? {
        recent(limit: 1).first
    }

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
    EditPromptWithTestSheet(prompt: SavedPrompt.defaultArticulate, onChange: {})
}

#Preview("New") {
    EditPromptWithTestSheet(prompt: nil, onChange: {})
}
