import SwiftUI

/// Bottom-sheet rewrite picker (Mockup 10 / plan §6.1).
///
/// Presented from `TranscriptDetailView`'s Rewrite button when the AI rewrite
/// model is `.ready`. Lists the user's saved prompts as tappable rows; tap
/// fires the existing `LLMClient.rewrite(text:systemPrompt:)` path and
/// dismisses the sheet. The result-handling lifecycle (running / success /
/// error) is owned by the host detail view — this sheet is a picker only.
///
/// ## Why a sheet (not a `confirmationDialog`)
///
/// Mockup 10 calls for a 360pt drawer with grabber, multi-row anatomy
/// (icon tile + title + secondary line), and a footer disclosure. The system
/// `confirmationDialog` the prior detail view used can't carry that visual
/// weight — the sheet replaces it.
///
/// ## Anatomy (plan §6.1)
///
/// - Grabber + `Cancel` (left) + `Rewrite` title + "N words · using <model>"
///   sub-line.
/// - One row per saved prompt. The default seeded prompt (the "Rewrite"
///   row at id `11111111-...`) renders with a coral `wand.and.stars` icon
///   + the "Default · polish without shortening" secondary copy from the
///   mockup. Additional user-created rows render with a purple
///   `list.bullet` icon by default — visually distinguishing user prompts
///   from the seeded default — and use a truncated systemPrompt preview
///   as the secondary line.
/// - "+ New prompt" footer row that dismisses the sheet and asks the host
///   to navigate the user to `AIRewriteSettingsView` (no inline creation).
/// - Disclosure footer: "Rewrite replaces the previous rewrite. Original
///   stays untouched." — verbatim from plan §6.1.
///
/// Sheet detent: `.height(360)` per plan §13 risk 6 — fixed-height drawer
/// keeps the layout stable across Dynamic Type sizes that would otherwise
/// blow past `.medium`.
struct RewritePickerSheet: View {

    /// Word count for the active transcript body, surfaced in the sub-line.
    let wordCount: Int

    /// Model display name to surface in the sub-line. Caller passes
    /// `JotDesign.activeRewriteModelDisplayName` so the sheet stays honest
    /// with the live provider.
    let modelDisplayName: String

    /// User's saved prompts, supplied by the host. Pre-sorted by
    /// `SavedPromptStore.all()` ordering.
    let prompts: [SavedPrompt]

    /// Fires when the user picks a prompt. Caller starts the in-process
    /// rewrite via `LLMClient.rewrite(...)`.
    let onPick: (SavedPrompt) -> Void

    /// Fires when the user taps the "+ New prompt" affordance. Caller is
    /// expected to dismiss the sheet (already handled here via `dismiss()`)
    /// and route to `AIRewriteSettingsView`.
    let onNewPrompt: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Stable id of the bundled default rewrite prompt — used to pick
    /// the coral wand glyph for the seeded row.
    private static let defaultRewriteID = SavedPrompt.defaultRewrite.id

    /// Stable id of the bundled bullet-points prompt — used to pick
    /// the purple `list.bullet` glyph + canon mockup copy. User-created
    /// prompts also default to the purple list glyph; the id-based branch
    /// only changes the secondary-line copy.
    private static let defaultBulletPointsID = SavedPrompt.defaultBulletPoints.id

    var body: some View {
        VStack(spacing: 0) {
            headerRow

            sublineRow
                .padding(.top, 6)
                .padding(.bottom, 18)

            // Prompt rows scroll within the sheet so 4+ user prompts don't
            // overflow the fixed 360pt detent (plan §6.1). The header, the
            // "+ New prompt" affordance, and the footer disclosure stay
            // pinned outside the ScrollView.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 10) {
                    ForEach(prompts) { prompt in
                        promptRow(prompt)
                    }
                }
            }
            .scrollIndicators(.automatic)

            VStack(spacing: 10) {
                newPromptRow
            }
            .padding(.top, 10)

            Spacer(minLength: 16)

            footerCopy
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(JotDesign.background.ignoresSafeArea())
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
    }

    // MARK: - Header / subline

    private var headerRow: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.jotMute)
            .accessibilityLabel("Cancel rewrite picker")

            Spacer()

            Text("Rewrite")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Spacer()

            // Symmetry spacer — matches the Cancel button's intrinsic
            // width so the title is visually centered without a layout
            // anchor on the sheet's parent.
            Text("Cancel")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 32)
    }

    private var sublineRow: some View {
        HStack(spacing: 0) {
            Spacer()
            Text("\(wordCount) \(wordCount == 1 ? "word" : "words") · using \(modelDisplayName)")
                .font(.system(size: 12))
                .foregroundStyle(Color.jotMute)
                .monospacedDigit()
                .accessibilityLabel("\(wordCount) \(wordCount == 1 ? "word" : "words"), using \(modelDisplayName)")
            Spacer()
        }
    }

    // MARK: - Prompt rows

    @ViewBuilder
    private func promptRow(_ prompt: SavedPrompt) -> some View {
        let kind = rowKind(for: prompt)

        Button {
            onPick(prompt)
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                IconBox(
                    symbol: kind.iconSymbol,
                    tint: kind.iconTint,
                    size: 44
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(prompt.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotInk)
                        .lineLimit(1)
                    Text(rowSecondary(for: prompt, kind: kind))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotMute)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotMuteWeak)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .fill(Color.white.opacity(0.75))
            )
            .overlay(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .strokeBorder(Color.jotMuteWeak.opacity(0.30), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(prompt.name). \(rowSecondary(for: prompt, kind: kind))")
        .accessibilityAddTraits(.isButton)
    }

    /// One of three visual kinds for a picker row, keyed by the stable id of
    /// the seeded defaults. User-created rows fall through to `.userPrompt`
    /// which renders with the purple list glyph — same as the seeded
    /// bullet-points row — so the picker stays visually unified for
    /// list-style prompts while singling out the coral "Rewrite" default.
    private enum RowKind {
        case defaultRewrite
        case defaultBulletPoints
        case userPrompt

        var iconSymbol: String {
            switch self {
            case .defaultRewrite: return "wand.and.stars"
            case .defaultBulletPoints, .userPrompt: return "list.bullet"
            }
        }

        var iconTint: Color {
            switch self {
            case .defaultRewrite: return Color.jotAccent
            case .defaultBulletPoints, .userPrompt: return Color.jotPromptPurple
            }
        }
    }

    private func rowKind(for prompt: SavedPrompt) -> RowKind {
        if prompt.id == Self.defaultRewriteID { return .defaultRewrite }
        if prompt.id == Self.defaultBulletPointsID { return .defaultBulletPoints }
        return .userPrompt
    }

    /// Secondary copy under the prompt name. Seeded defaults carry mockup-canon
    /// strings; user-created prompts surface a single-line preview of their
    /// saved system prompt so the picker is self-describing.
    private func rowSecondary(for prompt: SavedPrompt, kind: RowKind) -> String {
        switch kind {
        case .defaultRewrite:
            return "Default · polish without shortening"
        case .defaultBulletPoints:
            return "Default · one idea per bullet"
        case .userPrompt:
            let cleaned = prompt.systemPrompt
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return cleaned.isEmpty ? "Custom prompt" : cleaned
        }
    }

    private var newPromptRow: some View {
        Button {
            onNewPrompt()
            dismiss()
        } label: {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            Color.jotMuteWeak.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.jotMute)
                }
                .frame(width: 44, height: 44)

                Text("New prompt")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotMuteWeak)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a new rewrite prompt")
        .accessibilityHint("Opens AI Rewrite settings to create a new prompt")
    }

    // MARK: - Footer

    private var footerCopy: some View {
        Text("Rewrite replaces the previous rewrite. Original stays untouched.")
            .font(.system(size: 12))
            .foregroundStyle(Color.jotMute)
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .accessibilityLabel("Rewrite replaces the previous rewrite. Original stays untouched.")
    }
}

// MARK: - Prompt-purple accent

extension Color {
    /// Purple icon used for the "Bullet points" / user-prompt rows in the
    /// rewrite picker (Mockup 10). Distinct from `jotAccent` (coral) so the
    /// seeded default row reads as the visually primary option. Not part of
    /// Phase 1 tokens because nothing else in the system uses it yet;
    /// scoped to this file so the design system stays single-accent.
    fileprivate static let jotPromptPurple = Color(red: 0.55, green: 0.40, blue: 0.90)
}

#Preview {
    Color.gray
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            RewritePickerSheet(
                wordCount: 52,
                modelDisplayName: "Phi-4 mini",
                prompts: [SavedPrompt.defaultRewrite],
                onPick: { _ in },
                onNewPrompt: {}
            )
        }
}
