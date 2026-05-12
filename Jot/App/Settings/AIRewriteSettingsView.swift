import SwiftUI

/// Phase 5 — AI Settings rebuild (mockup 18).
///
/// Visual reskin of the existing AI Rewrite settings pane. The persistent
/// state surfaces stay identical:
///   - `AppGroup.aiRewriteEnabled` master toggle
///   - `LLMClientUIAdapter` for Phi-4 status
///   - `SavedPromptStore.all()` for the prompts list
///   - `AIRewriteDownloadBanner` pinned above the form during downloads
///
/// New chrome:
///   - MODEL section: GlassCard with purple `wand.and.stars` IconBox (44pt),
///     model name in Fraunces 18pt, green `StatusPill.success` "Ready",
///     "On your iPhone · about 2.4 GB" sub-line, and a "Switch model"
///     chevron row that pushes a single-option picker (`SwitchModelPicker`).
///   - PROMPTS section: SectionLabel "PROMPTS · Drag to reorder", a
///     GlassCard list of prompts with per-row IconBoxes (coral wand for
///     `defaultRewrite`, purple list.bullet for `defaultBulletPoints` +
///     user prompts), each with a trailing chevron that opens the
///     `EditPromptWithTestSheet`.
///   - "+ New prompt" full-width glass button.
///
/// Backend invariants preserved: download is auto-warmed only on
/// master-toggle ON with `.notReady` (or when the user explicitly taps
/// New / Retry); cancellation flows through `LLMClientUIAdapter.cancelDownload()`.
struct AIRewriteSettingsView: View {

    /// Provider-agnostic UI adapter wrapping the currently-resolved
    /// `LLMClient`. Captured on `.onAppear`.
    @State private var clientAdapter: LLMClientUIAdapter?

    /// Master toggle mirror.
    @State private var aiRewriteEnabled: Bool = AppGroup.aiRewriteEnabled

    /// Saved prompts.
    @State private var prompts: [SavedPrompt] = []

    /// Edit-prompt sheet target.
    @State private var sheet: SheetMode?

    /// Deletion confirmation target.
    @State private var deletionTarget: SavedPrompt?

    /// Switch-model picker presentation.
    @State private var showSwitchModelPicker: Bool = false

    private enum SheetMode: Identifiable {
        case add
        case edit(SavedPrompt)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let prompt): return "edit-\(prompt.id.uuidString)"
            }
        }
    }

    var body: some View {
        ZStack {
            JotDesign.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Phase 4 download banner stays pinned above the scroll
                // content while the adapter reports `.downloading`.
                if case .downloading(let fraction) = (clientAdapter?.observableStatus ?? .notReady) {
                    AIRewriteDownloadBanner(
                        fraction: fraction,
                        modelDisplayName: JotDesign.activeRewriteModelDisplayName,
                        onCancel: { cancelDownload() }
                    )
                    .padding(.horizontal, JotDesign.Spacing.pageMargin)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGap) {
                        masterToggleSection
                            .padding(.horizontal, JotDesign.Spacing.pageMargin)

                        Group {
                            modelSection
                            promptsSection
                        }
                        .padding(.horizontal, JotDesign.Spacing.pageMargin)
                        .disabled(!aiRewriteEnabled)
                        .opacity(aiRewriteEnabled ? 1.0 : 0.5)

                        Spacer(minLength: 24)
                    }
                    .padding(.top, 12)
                }
            }
        }
        .navigationTitle("AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if aiRewriteEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .add:
                EditPromptWithTestSheet(prompt: nil) {
                    reloadPrompts()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .edit(let prompt):
                EditPromptWithTestSheet(prompt: prompt) {
                    reloadPrompts()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        .sheet(isPresented: $showSwitchModelPicker) {
            SwitchModelPicker()
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        .alert(
            deletionAlertTitle,
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { presented in
                    if !presented { deletionTarget = nil }
                }
            ),
            presenting: deletionTarget
        ) { prompt in
            Button("Delete", role: .destructive) {
                SavedPromptStore.delete(id: prompt.id)
                deletionTarget = nil
                reloadPrompts()
            }
            Button("Cancel", role: .cancel) {
                deletionTarget = nil
            }
        } message: { _ in
            Text("This can't be undone.")
        }
        .onAppear {
            aiRewriteEnabled = AppGroup.aiRewriteEnabled
            SavedPromptStore.seedIfNeeded()
            reloadPrompts()
            rebuildAdapter()
            // Auto-warm gated on the master toggle. See the original
            // implementation for the full rationale around opt-in download
            // consent — preserved verbatim.
            if aiRewriteEnabled,
               let adapter = clientAdapter,
               case .notReady = adapter.observableStatus {
                triggerDownload()
            }
        }
        .onDisappear {
            clientAdapter?.stop()
        }
        .onChange(of: aiRewriteEnabled) { _, newValue in
            AppGroup.aiRewriteEnabled = newValue
            if newValue {
                if let adapter = clientAdapter,
                   case .notReady = adapter.observableStatus {
                    triggerDownload()
                }
            } else {
                cancelDownload()
            }
        }
    }

    // MARK: - Master toggle

    private var masterToggleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("AI REWRITE")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 14) {
                Toggle(isOn: $aiRewriteEnabled) {
                    HStack(spacing: 12) {
                        IconBox(symbol: "wand.and.stars", tint: Color.jotAccent, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable AI Rewrite")
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Color.jotInk)
                            Text("Lets the keyboard's Magic button rewrite selected text.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.jotMute)
                        }
                    }
                }
                .tint(.jotAccent)
                .frame(minHeight: 44)
            }
            .accessibilityLabel("Enable AI Rewrite")
        }
    }

    // MARK: - MODEL section

    @ViewBuilder
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("MODEL")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        IconBox(symbol: "wand.and.stars", tint: Color.purple, size: 44)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(JotDesign.activeRewriteModelDisplayName)
                                .font(.custom(JotType.frauncesSemiBold, size: 18))
                                .foregroundStyle(Color.jotInk)
                            Text("On your iPhone · about \(JotDesign.activeRewriteModelSize)")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.jotMute)
                        }

                        Spacer()

                        modelStatusPill
                    }

                    // Below the headline: model-state-specific actions
                    // (download, cancel, retry, free memory) so the user
                    // has a single place to operate on the LLM.
                    modelStateActions

                    Divider().opacity(0.4)

                    Button {
                        showSwitchModelPicker = true
                    } label: {
                        HStack(spacing: 10) {
                            Text("Switch model")
                                .font(.system(size: 16))
                                .foregroundStyle(Color.jotInk)
                            Spacer()
                            Text(JotDesign.activeRewriteModelDisplayName)
                                .font(.system(size: 15))
                                .foregroundStyle(Color.jotMute)
                            RowChevron()
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Switch model, currently \(JotDesign.activeRewriteModelDisplayName)")
                    .accessibilityHint("Opens the model picker")
                }
            }

            Text("Titles and tags use the system's built-in AI automatically.")
                .font(.footnote)
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var modelStatusPill: some View {
        switch clientAdapter?.observableStatus ?? .notReady {
        case .ready:
            StatusPill(label: "Ready", tint: .success)
        case .downloading(let fraction):
            StatusPill(label: "\(Int((fraction * 100).rounded()))%", tint: .info)
        case .loading:
            StatusPill(label: "Loading", tint: .info)
        case .evicted:
            StatusPill(label: "Unloaded", tint: .warning)
        case .error:
            StatusPill(label: "Error", tint: .warning)
        case .notReady:
            StatusPill(label: "Not downloaded", tint: .warning)
        }
    }

    @ViewBuilder
    private var modelStateActions: some View {
        let currentStatus: LLMClientStatus = clientAdapter?.observableStatus ?? .notReady
        switch currentStatus {
        case .notReady:
            Button {
                triggerDownload()
            } label: {
                Label("Download Phi-4 mini (~\(JotDesign.activeRewriteModelSize))", systemImage: "arrow.down.circle")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download Phi-4 mini")

        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(maxWidth: .infinity)
                Button(role: .destructive) {
                    cancelDownload()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .frame(minHeight: 44)

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading…")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.jotMute)
            }
            .frame(minHeight: 44, alignment: .leading)

        case .ready:
            Button {
                deleteModel()
            } label: {
                Text("Free memory")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Free memory")

        case .evicted:
            Button {
                triggerDownload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotAccent)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reload model")

        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                Button {
                    triggerDownload()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.jotAccent)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry download")
            }
        }
    }

    // MARK: - PROMPTS section

    @ViewBuilder
    private var promptsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel("PROMPTS · Drag to reorder")
                Spacer()
            }
            .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 0) {
                // SwiftUI's drag-to-reorder needs a `List` host. We embed a
                // bounded-height List inside the GlassCard so the visual
                // chrome stays editorial while we keep `.onMove`. The
                // explicit `frame(height:)` is computed from the row count
                // so the card grows with the list without scroll-in-scroll.
                List {
                    ForEach(prompts) { prompt in
                        promptRow(prompt)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deletionTarget = prompt
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Color.jotMuteWeak.opacity(0.3))
                            .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
                    }
                    .onMove { source, destination in
                        SavedPromptStore.reorder(source: source, destination: destination)
                        reloadPrompts()
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(max(prompts.count, 1)) * 64)
            }

            Button {
                sheet = .add
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                    Text("New prompt")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(Color.jotAccent)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 48)
                .modifier(JotDesign.Surface.regular.modifier(cornerRadius: JotDesign.Spacing.cardRadius))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New prompt")
        }
    }

    private func promptRow(_ prompt: SavedPrompt) -> some View {
        Button {
            sheet = .edit(prompt)
        } label: {
            HStack(spacing: 12) {
                IconBox(
                    symbol: promptIconSymbol(prompt),
                    tint: promptIconTint(prompt),
                    size: 32
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.name)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Color.jotInk)
                        .lineLimit(1)
                    Text(prompt.systemPrompt)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.jotMute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer()
                RowChevron()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit prompt \(prompt.name)")
        .accessibilityHint("Opens the prompt editor")
    }

    private func promptIconSymbol(_ prompt: SavedPrompt) -> String {
        if prompt.id == SavedPrompt.defaultRewrite.id { return "wand.and.stars" }
        return "list.bullet"
    }

    private func promptIconTint(_ prompt: SavedPrompt) -> Color {
        if prompt.id == SavedPrompt.defaultRewrite.id { return Color.jotAccent }
        return Color.purple
    }

    // MARK: - Helpers

    private var deletionAlertTitle: String {
        if let prompt = deletionTarget {
            return "Delete \"\(prompt.name)\"?"
        }
        return "Delete prompt?"
    }

    private func reloadPrompts() {
        prompts = SavedPromptStore.all()
    }

    private func rebuildAdapter() {
        clientAdapter?.stop()
        let client = LLMClientFactory.shared.client()
        let adapter = LLMClientUIAdapter(client: client)
        adapter.start()
        clientAdapter = adapter
    }

    private func triggerDownload() {
        if clientAdapter == nil {
            rebuildAdapter()
        }
        clientAdapter?.warm()
    }

    private func cancelDownload() {
        clientAdapter?.cancelDownload()
    }

    private func deleteModel() {
        clientAdapter?.deleteModel()
    }
}

// MARK: - Switch model picker

/// Single-row picker for the active rewrite model. Per plan §14.4 we show
/// the affordance even with one provider so the flow stays consistent when
/// a second provider lands. The single row is selected by default.
private struct SwitchModelPicker: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                JotDesign.background.ignoresSafeArea()

                VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGap) {
                    SectionLabel("REWRITE MODEL")
                        .padding(.horizontal, 4)

                    GlassCard(tier: .regular, padding: 14) {
                        HStack(spacing: 12) {
                            IconBox(symbol: "wand.and.stars", tint: Color.purple, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(JotDesign.activeRewriteModelDisplayName)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundStyle(Color.jotInk)
                                Text("On your iPhone · about \(JotDesign.activeRewriteModelSize)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.jotMute)
                            }
                            Spacer()
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.jotAccent)
                        }
                        .frame(minHeight: 44)
                    }

                    Text("Active rewrite model. Runs on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(Color.jotMute)
                        .padding(.horizontal, 4)

                    Spacer()
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 12)
            }
            .navigationTitle("Switch model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        AIRewriteSettingsView()
    }
}
