import SwiftUI

/// AI Settings screen (v0.9 visual language).
///
/// Rewrites run on Apple Foundation Models — there is no Jot-owned model, no
/// download, nothing to manage, and there is exactly one engine: the user's
/// saved prompts on Apple Intelligence (on-device, Private Cloud Compute as
/// the iOS 27 fallback). The former "Writing Tools" engine picker was retired
/// 2026-09-15. What the screen owns:
///   - The **engine strip**: Apple Intelligence readiness (`RewriteClient
///     .availability`) with a one-line explanation when it's off.
///   - `SavedPromptStore.all()` powers the prompts list, with drag-to-reorder,
///     swipe-to-delete, and tap-to-edit flowing into `EditPromptWithTestSheet`.
///   - The "+ New prompt" CTA presents `NewPromptSheet`.
///
/// Visual language:
///   - `WallpaperBackground`; italic serif "AI" 44pt + coral EXPERIMENTAL chip.
///   - Single compact engine strip (purple `wand.and.stars` IconTile).
///   - Each prompt row renders an IconTile + serif name + DEFAULT tag (for the
///     seeded prompts) + a mini BEFORE→AFTER sample block.
///   - Dashed coral "+ New prompt" card.
struct AIRewriteSettingsView: View {

    @State private var prompts: [SavedPrompt] = []
    @State private var sheet: SheetMode?
    @State private var deletionTarget: SavedPrompt?
    /// Live engine readiness, re-read on appear (Apple Intelligence can be
    /// toggled in Settings while this sheet is off-screen).
    @State private var availability: RewriteClient.Availability = .available
    /// Automatic cleanup (features.md §7.14): run a saved prompt on every
    /// dictation. Loaded on appear; every change saves straight through.
    @State private var cleanup = CleanupSettings.load()

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

                        engineStrip
                            .padding(.horizontal, 14)
                            .padding(.bottom, 18)

                        autoCleanupHeader
                            .padding(.horizontal, 22)
                            .padding(.bottom, 8)

                        autoCleanupCard
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
            availability = RewriteClient.availability
            RewriteClient.mirrorAvailabilityToAppGroup()
            SavedPromptStore.seedIfNeeded()
            reloadPrompts()
            cleanup = CleanupSettings.load()
        }
    }

    // MARK: - Hero

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("AI")
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

            Text("One-tap text transforms. Tap the wand in any transcript to run a prompt on it — powered by Apple Intelligence, nothing to download.")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Engine readiness

    private var isEngineAvailable: Bool {
        if case .available = availability { return true }
        return false
    }

    // MARK: - Engine strip (Apple Intelligence readiness)

    private var engineStrip: some View {
        LiquidGlassCard(paddingH: 14, paddingV: 11) {
            HStack(spacing: 12) {
                IconTile(
                    systemImage: "wand.and.stars",
                    tint: AIV09Tokens.purple,
                    shaded: AIV09Tokens.purpleShaded,
                    size: 28
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence")
                        .font(.system(size: 13.5, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(Color.jotPageInk)
                    HStack(spacing: 6) {
                        statusDot(ready: isEngineAvailable)
                        Text(engineSublineText)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 8)

                if !isEngineAvailable {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Settings")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.jotCoralTop)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open iPhone Settings")
                    .accessibilityHint("Turn on Apple Intelligence")
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var engineSublineText: String {
        switch availability {
        case .available:
            return RewriteClient.wouldUsePrivateCloudCompute
                ? "Ready · uses Private Cloud Compute"
                : "Ready · on your iPhone"
        case .unavailable(let reason):
            return reason
        }
    }

    @ViewBuilder
    private func statusDot(ready: Bool) -> some View {
        let color: Color = ready ? .jotSuccess : Color.jotCoralTop
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

    // MARK: - Automatic cleanup

    /// Which saved prompt the cleanup runs, resolved the same way the
    /// pipeline resolves it (chosen prompt → built-in Cleanup → legacy text).
    private var cleanupPromptName: String {
        CleanupSettings.resolvedPrompt(promptID: cleanup.promptID)?.name ?? "Cleanup"
    }

    private var autoCleanupHeader: some View {
        Text("AI cleanup")
            .font(JotType.sectionLabel)
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(Color.jotPageInkCaption)
    }

    /// Automatic cleanup (features.md §7.14) — the same glass card and row
    /// typography as the Settings screen's toggle rows, with a sparkles tile
    /// so it reads as one of the AI features rather than a stray toggle.
    /// When Apple Intelligence isn't ready the whole card dims and its rows
    /// are disabled; the first row's subline says what to turn on.
    private var autoCleanupCard: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            VStack(spacing: 0) {
                cleanupToggleRow
                if cleanup.enabled && isEngineAvailable {
                    cleanupRowDivider
                    cleanupPromptRow
                    cleanupRowDivider
                    cleanupPasteRow
                }
            }
        }
        .opacity(isEngineAvailable ? 1 : 0.5)
        .disabled(!isEngineAvailable)
        .animation(.easeInOut(duration: 0.2), value: cleanup.enabled)
    }

    private var cleanupRowDivider: some View {
        Divider().padding(.leading, JotDesign.Spacing.cardPaddingH + JotDesign.Spacing.tileRowSize + 14)
    }

    private static let settingsToggleGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    private var cleanupToggleSubline: String {
        if !isEngineAvailable { return "Needs Apple Intelligence — turn it on above" }
        if cleanup.enabled { return "Runs \u{201C}\(cleanupPromptName)\u{201D} after every dictation" }
        return "Polish each dictation with one of your prompts before it lands"
    }

    private var cleanupToggleRow: some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(systemImage: "sparkles", tint: AIV09Tokens.purple, shaded: AIV09Tokens.purpleShaded)

            VStack(alignment: .leading, spacing: 3) {
                Text("Clean up every dictation")
                    .font(JotType.rowTitle)
                    .foregroundStyle(Color.jotPageInk)
                    .tracking(-0.2)

                Text(cleanupToggleSubline)
                    .font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { cleanup.enabled },
                set: { on in
                    cleanup.enabled = on
                    cleanup.save()
                }
            ))
            .labelsHidden()
            .tint(Self.settingsToggleGreen)
            .accessibilityLabel("Clean up every dictation")
            .accessibilityHint("When on, every dictation is cleaned up by the chosen prompt")
        }
        .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var cleanupPromptRow: some View {
        Menu {
            ForEach(prompts) { prompt in
                Button {
                    cleanup.promptID = prompt.id
                    cleanup.save()
                } label: {
                    if prompt.id == CleanupSettings.resolvedPrompt(promptID: cleanup.promptID)?.id {
                        Label(prompt.name, systemImage: "checkmark")
                    } else {
                        Text(prompt.name)
                    }
                }
            }
        } label: {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Prompt")
                        .font(JotType.rowTitle)
                        .foregroundStyle(Color.jotPageInk)
                        .tracking(-0.2)
                    Text("Any of your saved prompts")
                        .font(JotType.rowSub)
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .lineSpacing(2)
                }

                Spacer(minLength: 12)

                Text(cleanupPromptName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.jotAccent)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
            .padding(.leading, JotDesign.Spacing.cardPaddingH + JotDesign.Spacing.tileRowSize + 14)
            .padding(.trailing, JotDesign.Spacing.cardPaddingH)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Cleanup prompt, \(cleanupPromptName)")
        .accessibilityHint("Choose which saved prompt cleans up each dictation")
    }

    private var cleanupPasteRow: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Paste the cleaned-up text")
                    .font(JotType.rowTitle)
                    .foregroundStyle(Color.jotPageInk)
                    .tracking(-0.2)
                Text(cleanup.pasteCleanedText
                     ? "Waits a few seconds so what lands is already clean"
                     : "Pastes your words right away; the cleaned-up version lands in the note\u{2019}s Rewrite tab a few seconds later")
                    .font(JotType.rowSub)
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { cleanup.pasteCleanedText },
                set: { on in
                    cleanup.pasteCleanedText = on
                    cleanup.save()
                }
            ))
            .labelsHidden()
            .tint(Self.settingsToggleGreen)
            .accessibilityLabel("Paste the cleaned-up text")
            .accessibilityHint("Off pastes your words right away and adds the cleaned-up version to the note afterwards")
        }
        .padding(.leading, JotDesign.Spacing.cardPaddingH + JotDesign.Spacing.tileRowSize + 14)
        .padding(.trailing, JotDesign.Spacing.cardPaddingH)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
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
        p.defaultKind != nil
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
        Text("Rewrites run on your iPhone. On iOS 27, a transcript too long for the on-device model is sent to Apple's Private Cloud Compute — end-to-end private, never stored.")
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
        prompt.defaultKind != nil
    }

    private var iconSymbol: String {
        switch prompt.defaultKind {
        case .articulate:  return "wand.and.stars"
        case .aiPrompt:    return "text.bubble"
        case .actionItems: return "checklist"
        case .email:       return "envelope"
        case nil:          return "list.bullet"
        }
    }

    private var iconTint: Color {
        switch prompt.defaultKind {
        case .articulate:  return JotDesign.JotSemanticIcon.ai
        case .aiPrompt:    return AIV09Tokens.teal
        case .actionItems: return AIV09Tokens.purple
        case .email:       return Color.jotSuccess
        case nil:          return AIV09Tokens.purple
        }
    }

    private var iconShaded: Color {
        switch prompt.defaultKind {
        case .articulate:  return JotDesign.JotSemanticIcon.aiShaded
        case .aiPrompt:    return AIV09Tokens.tealShaded
        case .actionItems: return AIV09Tokens.purpleShaded
        case .email:       return Color.jotSuccess.opacity(0.5)
        case nil:          return AIV09Tokens.purpleShaded
        }
    }

    private var description: String {
        switch prompt.defaultKind {
        case .articulate:  return "Polish dictation · keep voice"
        case .aiPrompt:    return "Structure for Claude · ChatGPT · etc"
        case .actionItems: return "Extract tasks · assignees · deadlines"
        case .email:       return "Business email · BLUF · subject line"
        case nil:
            // For user prompts, render the trimmed first line of the system prompt.
            let firstLine = prompt.systemPrompt
                .split(whereSeparator: { $0.isNewline })
                .first
                .map(String.init) ?? prompt.systemPrompt
            return firstLine
        }
    }

    private var beforeText: String? {
        switch prompt.defaultKind {
        case .articulate:
            return "yo can you hear me testing the new mic gating on the keyboard"
        case .aiPrompt:
            return "uh I'm trying to figure out why my swiftui list does weird animations when I scroll on iOS 18 but not 17 I think it has to do with the new identifiable thing"
        case .actionItems:
            return "ok so vineet you take the design ship by friday priya followup with legal monday i'll write the launch post next week"
        case .email:
            return "draft email to sarah pushing the deadline to next friday because design isn't done yet"
        case nil:
            return nil
        }
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
        switch prompt.defaultKind {
        case .articulate:
            Text("Yo, can you hear me? Testing the new mic gating on the keyboard.")
                .font(.system(size: 13))
                .foregroundStyle(Color.jotPageInk)
                .fixedSize(horizontal: false, vertical: true)
        case .aiPrompt:
            VStack(alignment: .leading, spacing: 4) {
                Text("**Context:** SwiftUI List shows unexpected animations when scrolling on iOS 18 — works fine on iOS 17. Suspect it's tied to the iOS 18 Identifiable changes.")
                Text("**Task:** Diagnose the cause and find a fix that works on both iOS 17 and 18.")
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.jotPageInk)
            .fixedSize(horizontal: false, vertical: true)
        case .actionItems:
            VStack(alignment: .leading, spacing: 1) {
                Text("• Vineet — ship design by Friday")
                Text("• Priya — follow up with legal Monday")
                Text("• Me — write launch post next week")
            }
            .font(.system(size: 13))
            .foregroundStyle(Color.jotPageInk)
        case .email:
            VStack(alignment: .leading, spacing: 4) {
                Text("Subject: Deadline push to next Friday")
                    .font(.system(size: 13, weight: .semibold))
                Text("Hi Sarah, I'd like to push the deadline to next Friday — design isn't done yet. Thanks.")
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Color.jotPageInk)
        case nil:
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

// MARK: - Shared v0.9 AI tokens

/// AI-rewrite-specific color tokens that aren't part of the broader
/// `JotDesign.JotSemanticIcon` palette. Kept local to the AI surface so
/// other screens don't accidentally adopt the engine-strip purple.
enum AIV09Tokens {
    /// `#7C5CFF` — engine-strip + bullet-points prompt tile top.
    static let purple = Color(red: 0x7C / 255, green: 0x5C / 255, blue: 0xFF / 255)

    /// `#664BD1` — engine-strip + bullet-points prompt tile shaded bottom.
    static let purpleShaded = Color(red: 0x66 / 255, green: 0x4B / 255, blue: 0xD1 / 255)

    /// `rgba(255,107,87,0.14)` — coral background fill for the EXPERIMENTAL chip.
    static let coralChipBg = Color(red: 0xFF / 255, green: 0x6B / 255, blue: 0x57 / 255).opacity(0.14)

    /// `#E0533F` — deep coral foreground for the EXPERIMENTAL chip.
    static let coralDeep = Color(red: 0xE0 / 255, green: 0x53 / 255, blue: 0x3F / 255)

    /// `#33B5A8` — AI-prompt tile top. Teal sits between the
    /// Articulate blue and the Action Items purple in the palette
    /// and is distinct from the green Email tile + the reserved
    /// coral.
    static let teal = Color(red: 0x33 / 255, green: 0xB5 / 255, blue: 0xA8 / 255)

    /// `#2A968B` — AI-prompt tile shaded bottom.
    static let tealShaded = Color(red: 0x2A / 255, green: 0x96 / 255, blue: 0x8B / 255)
}

#Preview {
    NavigationStack {
        AIRewriteSettingsView()
    }
}
