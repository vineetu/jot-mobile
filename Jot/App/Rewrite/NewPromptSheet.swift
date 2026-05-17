import SwiftUI

/// Phase 5 (v0.9 redesign) — New prompt sheet.
///
/// Bottom sheet drawer (`.large` detent) presented from
/// `AIRewriteSettingsView` when the user taps the dashed "+ New prompt" CTA.
/// Composes a brand-new `SavedPrompt`: name + system prompt + selectable
/// icon. The Save pill is disabled until both name and system prompt are
/// non-empty. Persistence goes through `SavedPromptStore.add(...)`.
///
/// Why this is separate from `EditPromptWithTestSheet`:
///   - The "Try this prompt" expansion only makes sense for an existing
///     prompt that already has a system instruction worth running. New
///     prompts start blank; the Try affordance is replaced here with a
///     `Start from a template` footer that scaffolds the editor.
///   - The icon picker is unique to creation — once saved, the seeded
///     icon decision is implicit in the prompt id.
struct NewPromptSheet: View {
    let onChange: () -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var systemPrompt: String = ""
    @State private var selectedIconIndex: Int = 0
    @State private var cursorVisible: Bool = true

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedSystemPrompt: String { systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedSystemPrompt.isEmpty }

    private var selectedIcon: NewPromptIconEntry {
        NewPromptSheet.iconPalette[selectedIconIndex]
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
                    VStack(alignment: .leading, spacing: 14) {
                        nameCard
                        iconPickerSection
                        systemPromptEditorCard
                        templateFooter
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 24)
                }
            }
        }
        .onAppear {
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
            .accessibilityLabel("Cancel new prompt")

            Spacer()

            Text("New prompt")
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

    // MARK: - Name card

    private var nameCard: some View {
        LiquidGlassCard(paddingH: 16, paddingV: 14) {
            HStack(spacing: 14) {
                IconTile(
                    systemImage: selectedIcon.symbol,
                    tint: selectedIcon.tint,
                    shaded: selectedIcon.shaded,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 3) {
                    TextField(
                        "",
                        text: $name,
                        prompt: Text("Name your prompt")
                            .font(.system(size: 19, weight: .medium, design: .serif).italic())
                            .foregroundColor(Color.jotPageInkSecondary.opacity(0.6))
                    )
                    .font(.system(size: 19, weight: .medium, design: .serif))
                    .foregroundStyle(Color.jotPageInk)
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { _, newValue in
                        if newValue.count > SavedPrompt.nameMaxLength {
                            name = String(newValue.prefix(SavedPrompt.nameMaxLength))
                        }
                    }
                    .accessibilityLabel("Prompt name")

                    Text("e.g. \u{201C}Translate to Spanish\u{201D}")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.jotPageInkSecondary.opacity(0.5))
                }

                Spacer()
            }
        }
    }

    // MARK: - Icon picker

    private var iconPickerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Icon")
                .font(JotType.sectionLabel)
                .tracking(1.5)
                .textCase(.uppercase)
                .foregroundStyle(Color.jotPageInkCaption)
                .padding(.horizontal, 8)

            LiquidGlassCard(paddingH: 12, paddingV: 14) {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8),
                    spacing: 8
                ) {
                    ForEach(NewPromptSheet.iconPalette.indices, id: \.self) { i in
                        iconTileButton(at: i)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func iconTileButton(at index: Int) -> some View {
        let entry = NewPromptSheet.iconPalette[index]
        let isSelected = (index == selectedIconIndex)
        Button {
            selectedIconIndex = index
        } label: {
            ZStack {
                if isSelected {
                    selectedIconTile(entry: entry)
                } else {
                    standardIconTile(entry: entry)
                }
            }
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Icon: \(entry.symbol)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func selectedIconTile(entry: NewPromptIconEntry) -> some View {
        let shape = RoundedRectangle(cornerRadius: 11, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [entry.tint, entry.shaded],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 38, height: 38)
            .overlay(
                shape.strokeBorder(Color.white, lineWidth: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .inset(by: -2)
                    .strokeBorder(entry.tint, lineWidth: 2)
            )
            .shadow(color: entry.tint.opacity(0.4), radius: 6, x: 0, y: 3)
            .overlay(
                Image(systemName: entry.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
            )
    }

    @ViewBuilder
    private func standardIconTile(entry: NewPromptIconEntry) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [entry.tint, entry.shaded],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 34, height: 34)
            .overlay(
                shape
                    .inset(by: 0.5)
                    .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
                    .blendMode(.plusLighter)
            )
            .overlay(shape.stroke(Color.black.opacity(0.06), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.08), radius: 1, x: 0, y: 1)
            .overlay(
                Image(systemName: entry.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.white)
            )
    }

    // MARK: - System prompt editor

    private var systemPromptEditorCard: some View {
        LiquidGlassCard(cornerRadius: 18, paddingH: 0, paddingV: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("System prompt")
                        .font(JotType.sectionLabel)
                        .tracking(1.5)
                        .textCase(.uppercase)
                        .foregroundStyle(Color.jotPageInkCaption)

                    Spacer()

                    BlinkingCaret(visible: cursorVisible)
                        .frame(width: 2, height: 14)

                    Text("\(systemPrompt.count) chars")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.jotPageInkSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
                    .background(Color.jotPageInkCaption.opacity(0.20))

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $systemPrompt)
                        .font(JotType.monoEditor)
                        .lineSpacing(1.6)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(Color.jotPageInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(minHeight: 200)
                        .onChange(of: systemPrompt) { _, newValue in
                            if newValue.count > SavedPrompt.systemPromptMaxLength {
                                systemPrompt = String(newValue.prefix(SavedPrompt.systemPromptMaxLength))
                            }
                        }
                        .accessibilityLabel("System prompt editor")

                    if systemPrompt.isEmpty {
                        placeholderText
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private var placeholderText: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Describe how Jot should transform the selected text.")
                .font(JotType.monoEditor)
                .lineSpacing(1.6)
                .foregroundStyle(Color.jotPageInkSecondary.opacity(0.6))
            Text("Tip: be specific about voice, length, and what to preserve. Test on a recording before saving.")
                .font(JotType.monoEditor)
                .lineSpacing(1.6)
                .foregroundStyle(Color.jotPageInkSecondary.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityHidden(true)
    }

    // MARK: - Template footer

    private var templateFooter: some View {
        LiquidGlassCard(cornerRadius: 16, paddingH: 14, paddingV: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.jotCoralTop.opacity(0.5))
                    Text("Start from a template")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.jotPageInk)
                    Spacer()
                    Text("Optional")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.jotPageInkSecondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(NewPromptSheet.templates.indices, id: \.self) { i in
                            templateChip(NewPromptSheet.templates[i])
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func templateChip(_ t: NewPromptTemplate) -> some View {
        let icon = NewPromptSheet.iconPalette[t.iconIndex]
        Button {
            systemPrompt = t.starter
            selectedIconIndex = t.iconIndex
        } label: {
            HStack(spacing: 6) {
                IconTile(
                    systemImage: icon.symbol,
                    tint: icon.tint,
                    shaded: icon.shaded,
                    size: 18
                )
                Text(t.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.jotPageInk)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.leading, 5)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.jotPageInk.opacity(0.06))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.jotPageInk.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Template: \(t.name)")
        .accessibilityHint("Fills the editor with a starter prompt")
    }

    // MARK: - Save

    private func saveAndDismiss() {
        guard canSave else { return }
        let new = SavedPrompt(
            id: UUID(),
            name: trimmedName,
            systemPrompt: trimmedSystemPrompt,
            createdAt: Date(),
            sortOrder: 0 // overridden by the store to "after current last"
        )
        SavedPromptStore.add(new)
        onChange()
        dismiss()
    }

    // MARK: - Cursor blink

    private func startCursorBlink() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                cursorVisible.toggle()
            }
        }
    }

    // MARK: - Static palette + template data

    static let iconPalette: [NewPromptIconEntry] = [
        // 0 — coral wand (Rewrite, More-formal template).
        .init(
            symbol: "wand.and.stars",
            tint: JotDesign.JotSemanticIcon.ai,
            shaded: JotDesign.JotSemanticIcon.aiShaded
        ),
        // 1 — purple bullet list (Bullet points, Action-items template).
        .init(
            symbol: "list.bullet",
            tint: AIV09Tokens.purple,
            shaded: AIV09Tokens.purpleShaded
        ),
        // 2 — cyan book (Translate-to template).
        .init(
            symbol: "character.book.closed",
            tint: JotDesign.JotSemanticIcon.vocabulary,
            shaded: JotDesign.JotSemanticIcon.vocabularyShaded
        ),
        // 3 — blue waveform.
        .init(
            symbol: "waveform",
            tint: JotDesign.JotSemanticIcon.speechModel,
            shaded: JotDesign.JotSemanticIcon.speechModelShaded
        ),
        // 4 — green sparkles (Make-it-shorter template).
        .init(
            symbol: "sparkles",
            tint: JotDesign.JotSemanticIcon.privacyOnDevice,
            shaded: JotDesign.JotSemanticIcon.privacyOnDeviceShaded
        ),
        // 5 — orange checkmark.
        .init(
            symbol: "checkmark.circle",
            tint: JotDesign.JotSemanticIcon.privacyMicReady,
            shaded: JotDesign.JotSemanticIcon.privacyMicReadyShaded
        ),
        // 6 — pink heart.
        .init(
            symbol: "heart.fill",
            tint: JotDesign.JotSemanticIcon.acknowledgements,
            shaded: JotDesign.JotSemanticIcon.acknowledgementsShaded
        ),
        // 7 — cyan text-align (helpSupport tint).
        .init(
            symbol: "text.alignleft",
            tint: JotDesign.JotSemanticIcon.helpSupport,
            shaded: JotDesign.JotSemanticIcon.helpSupportShaded
        )
    ]

    static let templates: [NewPromptTemplate] = [
        .init(
            name: "Translate to…",
            iconIndex: 2,
            starter: "Translate the selected text into [LANGUAGE]. Keep the same voice, tone, and meaning. Return only the translation. No commentary, labels, or alternatives."
        ),
        .init(
            name: "Make it shorter",
            iconIndex: 4,
            starter: "Rewrite the selected text more concisely while preserving every meaningful detail, claim, and qualifier. Do not add commentary. Return only the rewritten version."
        ),
        .init(
            name: "More formal",
            iconIndex: 0,
            starter: "Rewrite the selected text in a more formal, professional register. Keep the meaning, structure, and every detail intact. Return only the rewritten version. No commentary."
        ),
        .init(
            name: "Action items",
            iconIndex: 1,
            starter: "Extract the selected text as a list of clear, parallel action items. Each item starts with a verb. Preserve every distinct action mentioned. Return only the bulleted list with \"- \" markers."
        )
    ]
}

// MARK: - Local data types

struct NewPromptIconEntry: Sendable {
    let symbol: String
    let tint: Color
    let shaded: Color
}

struct NewPromptTemplate: Sendable {
    let name: String
    let iconIndex: Int
    let starter: String
}

#Preview {
    NewPromptSheet(onChange: {})
}
