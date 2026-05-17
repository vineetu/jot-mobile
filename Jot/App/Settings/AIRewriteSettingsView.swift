import SwiftUI

/// Phase 5 (v0.9 redesign) — AI Settings screen.
///
/// Re-skinned to match `design_handoff_jot_ux/design/ai.jsx`'s
/// `AISettingsScreen`. The behavioral surface is unchanged:
///   - `AppGroup.aiRewriteEnabled` master toggle drives auto-warm.
///   - `LLMClientUIAdapter` mirrors Phi-4 status for the model strip.
///   - `SavedPromptStore.all()` powers the prompts list, with drag-to-reorder,
///     swipe-to-delete, and tap-to-edit flowing into `EditPromptWithTestSheet`.
///   - Model status (incl. in-progress download with cancel) lives solely in
///     the compact model strip; the legacy top-pinned `AIRewriteDownloadBanner`
///     was removed to eliminate a cold-launch flicker and avoid redundant
///     status surfaces.
///   - Long-press on the model strip surfaces "Change model" / "Delete model"
///     (destructive) — the only way to purge the on-device model from this
///     screen. Wired to `LLMClientUIAdapter.deleteModel()`.
///   - The "+ New prompt" CTA now presents the v0.9 `NewPromptSheet` (was the
///     edit sheet in name-empty mode).
///
/// Visual changes:
///   - `WallpaperBackground` replaces `JotDesign.background`.
///   - Italic serif "AI." 44pt + coral EXPERIMENTAL chip hero block.
///   - Single compact model strip (purple `wand.and.stars` IconTile) replaces
///     the older MODEL card; `Change` opens `SwitchModelPicker`.
///   - Each prompt row now renders an IconTile + serif name + DEFAULT tag
///     (for the two seeded prompts) + a mini BEFORE→AFTER sample block.
///   - Dashed coral "+ New prompt" card replaces the plain glass row.
struct AIRewriteSettingsView: View {

    @State private var clientAdapter: LLMClientUIAdapter?
    @State private var aiRewriteEnabled: Bool = AppGroup.aiRewriteEnabled
    @State private var prompts: [SavedPrompt] = []
    @State private var sheet: SheetMode?
    @State private var deletionTarget: SavedPrompt?
    @State private var showSwitchModelPicker: Bool = false
    @State private var showDeleteModelConfirm: Bool = false

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
            WallpaperBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        heroBlock
                            .padding(.horizontal, 22)
                            .padding(.bottom, 18)

                        masterToggleCard
                            .padding(.horizontal, 14)
                            .padding(.bottom, 14)

                        Group {
                            modelStrip
                                .padding(.horizontal, 14)
                                .padding(.bottom, 18)

                            promptsHeader
                                .padding(.horizontal, 22)
                                .padding(.bottom, 8)

                            promptsCard
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)

                            newPromptCTA
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)

                            footerCaption
                                .padding(.horizontal, 22)
                                .padding(.bottom, 8)
                        }
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
        .sheet(item: $sheet) { mode in
            switch mode {
            case .add:
                NewPromptSheet(onChange: reloadPrompts)
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
            SwitchModelPicker(onChange: {
                // Provider flipped — tear down the previous adapter so the
                // model strip re-reads `currentProvider` and reflects the
                // new client's on-disk + warm state. The factory itself
                // evicts the old client lazily on the next `.client()` call.
                rebuildAdapter()
            })
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

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("AI.")
                    .font(JotType.displaySerif(44))
                    .tracking(-1.6)
                    .foregroundStyle(Color.jotPageInk)

                Text("Experimental")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(AIV09Tokens.coralDeep)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(AIV09Tokens.coralChipBg)
                    )
            }

            Text("One-tap text transforms. Tap the wand in any transcript to run a prompt on selected text.")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Master toggle (kept as a small Liquid Glass card above the model strip)

    private var masterToggleCard: some View {
        LiquidGlassCard(paddingV: 12) {
            Toggle(isOn: $aiRewriteEnabled) {
                HStack(spacing: 12) {
                    IconTile(
                        systemImage: "wand.and.stars",
                        tint: JotDesign.JotSemanticIcon.ai,
                        shaded: JotDesign.JotSemanticIcon.aiShaded,
                        size: 32
                    )
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable AI Rewrite")
                            .font(JotType.rowTitle)
                            .foregroundStyle(Color.jotPageInk)
                        Text("Lets the keyboard's Magic button rewrite selected text.")
                            .font(JotType.rowSub)
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .tint(.jotCoralTop)
            .frame(minHeight: 44)
        }
        .accessibilityLabel("Enable AI Rewrite")
    }

    // MARK: - Compact model strip

    @ViewBuilder
    private var modelStrip: some View {
        LiquidGlassCard(paddingH: 14, paddingV: 11) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    IconTile(
                        systemImage: "wand.and.stars",
                        tint: AIV09Tokens.purple,
                        shaded: AIV09Tokens.purpleShaded,
                        size: 28
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(JotDesign.activeRewriteModelDisplayName)
                                .font(.system(size: 13.5, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundStyle(Color.jotPageInk)
                            Text("· \(JotDesign.activeRewriteModelSize) · on-device")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(Color.jotPageInkSecondary)
                                .lineLimit(1)
                        }
                        modelStripSubline
                    }

                    Spacer(minLength: 8)

                    Button {
                        showSwitchModelPicker = true
                    } label: {
                        Text("Change")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.jotCoralTop)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Change rewrite model")
                    .accessibilityHint("Opens the model picker")
                }

                // Inline action row for non-ready states so the user keeps
                // a single place to operate on the LLM (download / cancel /
                // retry / free memory).
                if !isReady {
                    Divider().opacity(0.35)
                    modelStateActions
                }
            }
            .contentShape(Rectangle())
            // Long-press the strip to expose Change / Delete. The inline
            // "Change" button remains the primary tap target; the menu adds
            // the missing destructive purge path without taking over the
            // row's tap behavior. The "Delete model" entry is only
            // meaningful when there are weights on-disk to remove — so we
            // hide it when the adapter reports `.notReady`.
            .contextMenu {
                Button {
                    showSwitchModelPicker = true
                } label: {
                    Label("Change model", systemImage: "arrow.left.arrow.right")
                }

                if canDeleteModel {
                    Button(role: .destructive) {
                        showDeleteModelConfirm = true
                    } label: {
                        Label("Delete model", systemImage: "trash")
                    }
                }
            }
            .confirmationDialog(
                "Delete \(JotDesign.activeRewriteModelDisplayName)?",
                isPresented: $showDeleteModelConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete model", role: .destructive) {
                    clientAdapter?.deleteModel()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("You'll need to re-download it (\(JotDesign.activeRewriteModelSize)) to use AI rewrite again.")
            }
        }
    }

    /// The "Delete model" context-menu entry is only meaningful once weights
    /// exist on-device or in-memory. While the adapter is `.notReady` there
    /// is nothing to purge, so we hide the destructive affordance.
    private var canDeleteModel: Bool {
        switch (clientAdapter?.observableStatus ?? .notReady) {
        case .ready, .loading, .evicted, .error:
            return true
        case .downloading, .notReady:
            return false
        }
    }

    @ViewBuilder
    private var modelStripSubline: some View {
        let status = clientAdapter?.observableStatus ?? .notReady
        HStack(spacing: 6) {
            statusDot(for: status)

            Text(modelSublineText(for: status))
                .font(.system(size: 11.5))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func statusDot(for status: LLMClientStatus) -> some View {
        let color: Color = {
            switch status {
            case .ready: return .jotSuccess
            case .downloading, .loading: return .jotBlueTop
            case .error: return .jotWarning
            case .evicted, .notReady: return Color.jotCoralTop
            }
        }()
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: 2.5)
                    .frame(width: 11, height: 11)
            )
            .frame(width: 11, height: 11)
    }

    private func modelSublineText(for status: LLMClientStatus) -> String {
        switch status {
        case .ready:
            return "Ready · audio never leaves your iPhone"
        case .downloading(let fraction):
            return "Downloading… \(Int((fraction * 100).rounded()))%"
        case .loading:
            return "Loading model…"
        case .evicted:
            return "Unloaded — tap Reload below"
        case .error(let message):
            return "Error · \(message)"
        case .notReady:
            return "Not downloaded yet"
        }
    }

    private var isReady: Bool {
        if case .ready = (clientAdapter?.observableStatus ?? .notReady) { return true }
        return false
    }

    @ViewBuilder
    private var modelStateActions: some View {
        let status = clientAdapter?.observableStatus ?? .notReady
        switch status {
        case .notReady:
            Button {
                triggerDownload()
            } label: {
                Label("Download \(JotDesign.activeRewriteModelDisplayName) (~\(JotDesign.activeRewriteModelSize))", systemImage: "arrow.down.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.jotCoralTop)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Download \(JotDesign.activeRewriteModelDisplayName)")

        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction)
                    .frame(maxWidth: .infinity)
                Button(role: .destructive) {
                    cancelDownload()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
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
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)

        case .ready:
            EmptyView()

        case .evicted:
            Button {
                triggerDownload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.jotCoralTop)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Reload model")

        case .error(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                Button {
                    triggerDownload()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.jotCoralTop)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry download")
            }
        }
    }

    // MARK: - Prompts section

    private var promptsHeader: some View {
        HStack {
            Text("Your prompts · \(prompts.count)")
                .font(JotType.sectionLabel)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(Color.jotPageInkCaption)
            Spacer()
            Text("Drag to reorder")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Color.jotCoralTop)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var promptsCard: some View {
        // Custom drag-to-reorder using a List inside a Liquid Glass surface.
        // The card itself uses no inner padding so the rows can render their
        // own generous vertical rhythm.
        LiquidGlassCard(cornerRadius: 20, paddingH: 0, paddingV: 0) {
            List {
                ForEach(prompts) { prompt in
                    PromptRowV09(
                        prompt: prompt,
                        isLast: prompt.id == prompts.last?.id,
                        onTap: { sheet = .edit(prompt) }
                    )
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            deletionTarget = prompt
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
                .onMove { source, destination in
                    SavedPromptStore.reorder(source: source, destination: destination)
                    reloadPrompts()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .frame(height: estimatedPromptsListHeight)
        }
    }

    private var estimatedPromptsListHeight: CGFloat {
        // Each row renders header + description + before quote (2 lines) +
        // arrow + after content (up to 3 lines). Built-in seeded prompts get
        // the full before→after sample block (~210pt); user-created prompts
        // skip the sample and render ~130pt.
        prompts.reduce(into: CGFloat(0)) { acc, p in
            acc += isBuiltinSample(p) ? 210 : 130
        }
    }

    private func isBuiltinSample(_ p: SavedPrompt) -> Bool {
        p.id == SavedPrompt.defaultRewrite.id || p.id == SavedPrompt.defaultBulletPoints.id
    }

    // MARK: - New prompt CTA

    private var newPromptCTA: some View {
        Button {
            sheet = .add
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .semibold))
                Text("New prompt")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(Color.jotCoralTop)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.jotCoralTop.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        Color.jotCoralTop.opacity(0.45),
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New prompt")
        .accessibilityHint("Create a new rewrite prompt")
    }

    // MARK: - Footer

    private var footerCaption: some View {
        Text("Titles and tags use the system's built-in AI automatically. They don't need a custom prompt.")
            .font(JotType.rowSub)
            .foregroundStyle(Color.jotPageInkCaption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
}

// MARK: - Prompt row

/// v0.9 prompt row used inside the prompts card on `AIRewriteSettingsView`.
/// Built-in seeded prompts render with a canonical before→after sample;
/// user-created prompts show a truncated preview of their system prompt.
private struct PromptRowV09: View {
    let prompt: SavedPrompt
    let isLast: Bool
    let onTap: () -> Void

    private var isBuiltin: Bool {
        prompt.id == SavedPrompt.defaultRewrite.id
            || prompt.id == SavedPrompt.defaultBulletPoints.id
    }

    private var iconSymbol: String {
        if prompt.id == SavedPrompt.defaultRewrite.id { return "wand.and.stars" }
        return "list.bullet"
    }

    private var iconTint: Color {
        if prompt.id == SavedPrompt.defaultRewrite.id { return JotDesign.JotSemanticIcon.ai }
        return AIV09Tokens.purple
    }

    private var iconShaded: Color {
        if prompt.id == SavedPrompt.defaultRewrite.id { return JotDesign.JotSemanticIcon.aiShaded }
        return AIV09Tokens.purpleShaded
    }

    private var description: String {
        if prompt.id == SavedPrompt.defaultRewrite.id {
            return "Polish without shortening · sentence-by-sentence"
        }
        if prompt.id == SavedPrompt.defaultBulletPoints.id {
            return "Reformat into a clean list · keep voice"
        }
        // For user prompts, render the trimmed first line of the system prompt.
        let firstLine = prompt.systemPrompt
            .split(whereSeparator: { $0.isNewline })
            .first
            .map(String.init) ?? prompt.systemPrompt
        return firstLine
    }

    private var beforeText: String? {
        if prompt.id == SavedPrompt.defaultRewrite.id {
            return "yo can you hear me testing the new mic gating on the keyboard"
        }
        if prompt.id == SavedPrompt.defaultBulletPoints.id {
            return "three things today shipped the chrome change talked to priya about onboarding drafted the ai sheet copy"
        }
        return nil
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                rowBody
                if !isLast {
                    rowDivider
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit prompt \(prompt.name)")
        .accessibilityHint("Opens the prompt editor")
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(
                systemImage: iconSymbol,
                tint: iconTint,
                shaded: iconShaded,
                size: 36
            )

            rowTextColumn

            Spacer(minLength: 6)

            DragDotsHandle()
                .padding(.top, 6)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
    }

    private var rowDivider: some View {
        Divider()
            .background(Color.jotPageInkCaption.opacity(0.20))
            .padding(.horizontal, 18)
    }

    private var rowTextColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowNameRow

            Text(description)
                .font(.system(size: 12.5))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineLimit(2)

            if let before = beforeText {
                rowSampleBlock(before: before)
            }
        }
    }

    private var rowNameRow: some View {
        HStack(spacing: 6) {
            Text(prompt.name)
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .tracking(-0.3)
                .foregroundStyle(Color.jotPageInk)
                .lineLimit(1)

            if isBuiltin {
                defaultTag
            }
        }
    }

    private var defaultTag: some View {
        Text("Default")
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(Color.jotPageInkCaption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.jotPageInk.opacity(0.08))
            )
    }

    private func rowSampleBlock(before: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\u{201C}\(before)\u{201D}")
                .font(.system(size: 12.5).italic())
                .foregroundStyle(Color.jotPageInkSecondary.opacity(0.85))
                .lineSpacing(2)
                .lineLimit(2)
                .padding(.top, 6)

            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.jotCoralTop)
                Text(prompt.name)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Color.jotCoralTop)
            }

            afterContent()
        }
    }

    @ViewBuilder
    private func afterContent() -> some View {
        if prompt.id == SavedPrompt.defaultRewrite.id {
            Text("Yo, can you hear me? Testing the new mic gating on the keyboard.")
                .font(.system(size: 13))
                .foregroundStyle(Color.jotPageInk)
                .fixedSize(horizontal: false, vertical: true)
        } else if prompt.id == SavedPrompt.defaultBulletPoints.id {
            VStack(alignment: .leading, spacing: 1) {
                Text("• Shipped the chrome change")
                Text("• Talked to Priya about onboarding")
                Text("• Drafted the AI sheet copy")
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.jotPageInk)
        } else {
            EmptyView()
        }
    }
}

private struct DragDotsHandle: View {
    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 4) {
                    Circle().frame(width: 2.8, height: 2.8)
                    Circle().frame(width: 2.8, height: 2.8)
                }
            }
        }
        .foregroundStyle(Color.jotPageInkSecondary.opacity(0.30))
        .frame(width: 14, height: 18)
        .accessibilityHidden(true)
    }
}

// MARK: - Switch model picker

/// Two-row picker for the active rewrite model.
///
/// Lists Qwen 3.5 4B (default / recommended) and Phi-4 mini (alternate).
/// Tapping a row persists the selection via `LLMClientFactory.setProvider(_:)`
/// — the next rewrite call will rebuild the underlying `LLMClient`. The
/// `onChange` callback fed by the parent view rebuilds its adapter so the
/// model strip reflects the new provider's download state immediately.
///
/// Each row shows:
///   - Provider name + per-provider size.
///   - A small "Default" / "Recommended" badge on Qwen.
///   - The current model's status dot (Ready / Downloading / Not downloaded)
///     so the user can see at a glance whether picking will trigger a
///     download.
///   - A trailing checkmark on the currently-active row.
///
/// Selecting a non-downloaded provider does NOT auto-trigger a download —
/// the user explicitly downloads from the AI Rewrite settings page after
/// switching. This matches the opt-in download pattern the brief calls for.
private struct SwitchModelPicker: View {
    @Environment(\.dismiss) private var dismiss
    let onChange: () -> Void

    /// Local mirror of the persisted selection so taps update the UI
    /// immediately without round-tripping through `LLMClientFactory`.
    @State private var selectedProvider: LLMProvider = LLMClientFactory.shared.currentProvider

    var body: some View {
        NavigationStack {
            ZStack {
                WallpaperBackground().ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGapV09) {
                        Text("Rewrite model")
                            .font(JotType.sectionLabel)
                            .tracking(1.5)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.jotPageInkCaption)
                            .padding(.horizontal, 4)

                        VStack(spacing: 10) {
                            providerRow(.qwen35, badge: "Default")
                            providerRow(.phi4, badge: nil)
                        }

                        Text("Picking a different model doesn't start the download — switch, then tap Download on the AI Rewrite screen if you want the new model on your iPhone.")
                            .font(.footnote)
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .padding(.horizontal, 4)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, JotDesign.Spacing.pageGutter)
                    .padding(.top, 12)
                }
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

    @ViewBuilder
    private func providerRow(_ provider: LLMProvider, badge: String?) -> some View {
        let isSelected = selectedProvider == provider
        LiquidGlassCard(paddingV: 14) {
            HStack(spacing: 12) {
                IconTile(
                    systemImage: "wand.and.stars",
                    tint: AIV09Tokens.purple,
                    shaded: AIV09Tokens.purpleShaded,
                    size: 36
                )
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(provider.displayName)
                            .font(JotType.rowTitle)
                            .foregroundStyle(Color.jotPageInk)
                        if let badge {
                            Text(badge)
                                .font(.system(size: 9.5, weight: .bold))
                                .tracking(0.8)
                                .textCase(.uppercase)
                                .foregroundStyle(AIV09Tokens.coralDeep)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(AIV09Tokens.coralChipBg)
                                )
                        }
                    }
                    Text("On your iPhone · about \(provider.displaySize)")
                        .font(JotType.rowSub)
                        .foregroundStyle(Color.jotPageInkSecondary)
                    providerStatusLine(for: provider)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotCoralTop)
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("\(provider.displayName), about \(provider.displaySize)\(isSelected ? ", selected" : "")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .onTapGesture {
            guard selectedProvider != provider else { return }
            selectedProvider = provider
            LLMClientFactory.shared.setProvider(provider)
            onChange()
        }
    }

    /// Per-provider readiness dot + caption. We check the on-disk snapshot
    /// for each provider independently so the row honestly reflects what's
    /// actually available — not just the currently-active client.
    @ViewBuilder
    private func providerStatusLine(for provider: LLMProvider) -> some View {
        let isInstalled = isSnapshotPresent(for: provider)
        HStack(spacing: 6) {
            Circle()
                .fill(isInstalled ? Color.jotSuccess : Color.jotCoralTop)
                .frame(width: 6, height: 6)
            Text(isInstalled ? "Downloaded" : "Not downloaded")
                .font(.system(size: 11.5))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
    }

    private func isSnapshotPresent(for provider: LLMProvider) -> Bool {
        switch provider {
        case .qwen35: return Qwen35Client.snapshotPresentOnDisk()
        case .phi4: return Phi4Client.snapshotPresentOnDisk()
        }
    }
}

// MARK: - Shared v0.9 AI tokens

/// AI-rewrite-specific color tokens that aren't part of the broader
/// `JotDesign.JotSemanticIcon` palette. Kept local to the AI surface so
/// other screens don't accidentally adopt the model-strip purple.
enum AIV09Tokens {
    /// `#7C5CFF` — model-strip + bullet-points prompt tile top.
    static let purple = Color(red: 0x7C / 255, green: 0x5C / 255, blue: 0xFF / 255)

    /// `#664BD1` — model-strip + bullet-points prompt tile shaded bottom.
    static let purpleShaded = Color(red: 0x66 / 255, green: 0x4B / 255, blue: 0xD1 / 255)

    /// `rgba(255,107,87,0.14)` — coral background fill for the EXPERIMENTAL chip.
    static let coralChipBg = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x57 / 255).opacity(0.14)

    /// `#E0533F` — deep coral foreground for the EXPERIMENTAL chip.
    static let coralDeep = Color(red: 0xE0 / 255, green: 0x53 / 255, blue: 0x3F / 255)
}

#Preview {
    NavigationStack {
        AIRewriteSettingsView()
    }
}
