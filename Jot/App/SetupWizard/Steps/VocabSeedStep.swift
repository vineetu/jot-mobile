//
//  VocabSeedStep.swift
//  Jot
//
//  Phase 6 — wizard panel Optional Step 1 (Vocab Seed).
//  Teal book IconTile + "Teach Jot some words" + a list of the user's
//  existing vocabulary terms (deletable) above a text-field row with a
//  coral "+" button that pushes new entries into `VocabularyStore.shared`.
//
//  The store is held as `@State` (not a plain `let`) so SwiftUI's
//  Observation tracking sees reads of `store.terms` and the list rerenders
//  when adds/removes mutate the file-backed store. Matches the pattern
//  used by `VocabularySettingsView`. Without this the wizard rendered as
//  a first-time seed step and never surfaced the user's prior terms on a
//  re-run of the wizard from Settings.
//

import SwiftUI

struct VocabSeedStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onAdvance: () -> Void
    let onSkip: () -> Void

    @State private var draftTerm: String = ""
    @FocusState private var fieldFocused: Bool

    // `@State` (not `let`) so reads of `store.terms` participate in
    // Observation tracking — see file-level note.
    @State private var store = VocabularyStore.shared

    private static let placeholderTerms = ["Parakeet", "Phi-4"]

    /// Terms surfaced in the wizard list. Filters out blank rows (the
    /// store appends a blank row inside `addBlankTerm()` before the
    /// caller fills its text in a subsequent `update`, so a transient
    /// blank can appear if `update` hasn't landed yet).
    private var visibleTerms: [VocabTerm] {
        store.terms.filter { !$0.isBlank }
    }

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .optional(current: 0), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 18) {
                Spacer(minLength: 24)

                IconTile(
                    systemImage: "character.book.closed.fill",
                    tint: JotDesign.JotSemanticIcon.vocabulary,
                    shaded: JotDesign.JotSemanticIcon.vocabularyShaded,
                    size: JotDesign.Spacing.tileHeroSize
                )
                .accessibilityHidden(true)

                WizardItalicTitle(text: "Teach Jot some words", size: 30)
                    .padding(.top, 4)
                WizardBody(text: "Names or unusual terms Jot might mishear.")

                vocabularyList
                    .padding(.top, 16)

                entryRow
                    .padding(.top, 10)

                WizardItalicNote(text: "You can edit these any time in Settings → Vocabulary.")
                    .padding(.top, 8)

                // Trailing spacer keeps the entry field visually separated
                // from the bottom CTA stack when the keyboard is dismissed.
                // Without it the field sat ~10pt above Done, which read
                // as cramped.
                Spacer(minLength: 32)
            }
        } footer: {
            // Done is the primary commit action — promote to the coral
            // pill used by W2/W3/W7. Skip stays as the muted text button
            // beneath it. SwiftUI's default keyboard avoidance lifts the
            // footer above the system keyboard while the text field is
            // focused.
            WizardPrimaryButton(title: "Done", action: commitAndAdvance)
            WizardSecondaryTextButton(title: "Skip", action: onSkip)
        }
        .onAppear {
            // Pick up edits made outside this session (e.g., the user
            // edited the file via Files app, or another path mutated the
            // store and the singleton's in-memory array is stale).
            // Mirrors `VocabularySettingsView.onAppear`.
            store.load()
        }
    }

    // MARK: - Entry row

    private var entryRow: some View {
        HStack(spacing: 10) {
            TextField("Liquid Glass", text: $draftTerm)
                .font(.custom(JotType.frauncesRegular, size: 18))
                .foregroundStyle(Color.jotInk)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled(true)
                .focused($fieldFocused)
                .onSubmit { addCurrentTerm() }
                .submitLabel(.done)

            Button(action: addCurrentTerm) {
                ZStack {
                    Circle()
                        .fill(Color.jotAccent)
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
            }
            .disabled(draftTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Add term")
            // ≥44pt hit area without bloating the visual tile.
            .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 52)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.55), lineWidth: 0.5)
        )
    }

    /// List of existing terms with an xmark delete affordance per row, or
    /// visual-only example rows before the user has saved vocabulary terms.
    /// The wizard panel is rendered inside a `ScrollView` already (see
    /// `WizardPanel`), so the list scrolls naturally with the panel when
    /// the term count grows. Settings → Vocabulary uses Form-row swipe-
    /// to-delete; we can't host a `List` inside the wizard's custom
    /// VStack chrome, so we mirror the same delete capability with a
    /// trailing xmark button. One persistence path (`store.delete(id:)`).
    private var vocabularyList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if visibleTerms.isEmpty {
                ForEach(Self.placeholderTerms, id: \.self) { term in
                    placeholderTermRow(term)
                }
            } else {
                ForEach(visibleTerms) { term in
                    storedTermRow(term)
                }
            }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(visibleTerms.isEmpty ? "Vocabulary examples" : "Vocabulary terms")
    }

    private func storedTermRow(_ term: VocabTerm) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Color.jotMuteWeak)
            Text(term.text)
                .font(.system(size: 14))
                .foregroundStyle(Color.jotInk)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Button {
                store.delete(id: term.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.jotMuteWeak)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 32, alignment: .trailing)
            .accessibilityLabel("Remove \(term.text)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func placeholderTermRow(_ term: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 6))
                .foregroundStyle(Color.jotMuteWeak.opacity(0.75))
            Text(term)
                .font(.system(size: 14))
                .foregroundStyle(Color.jotPageInkCaption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }

    // MARK: - Actions

    private func addCurrentTerm() {
        let trimmed = draftTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let blank = store.addBlankTerm()
        store.update(id: blank.id, text: trimmed, aliases: [])
        draftTerm = ""
        fieldFocused = true
    }

    private func commitAndAdvance() {
        // Sweep any unsubmitted text into the store — the user may have
        // typed a term and tapped Done without hitting the + button.
        addCurrentTerm()
        onAdvance()
    }
}
