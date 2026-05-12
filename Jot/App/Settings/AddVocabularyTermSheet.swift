import SwiftUI

/// Phase 5 — Add term sheet (mockup 17).
///
/// Bottom sheet over the Vocabulary list. Renders a single big Fraunces 22pt
/// `TextField` with a red blinking caret + italic Fraunces sub-line. The
/// iOS system keyboard is supplied by the OS — autocorrect suggestions are
/// the platform default.
///
/// On Save the trimmed term is persisted through `VocabularyStore.shared`
/// using the existing `addBlankTerm()` + `update(id:text:)` path so the
/// boost-model rescorer's `save()` → `rebuildVocabulary` hook fires exactly
/// once. Cancel discards.
///
/// The existing `VocabularySettingsView` Edit-mode inline term creation
/// (the `Button { addTerm() }` row inside the Form) is preserved as an
/// alternative entry — this sheet is wired to a new floating "+ Add term"
/// FAB. Two entry points, one persistence path.
struct AddVocabularyTermSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var term: String = ""
    @FocusState private var focused: Bool

    private var trimmed: String {
        term.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool { !trimmed.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header

            Spacer(minLength: 18)

            field

            Spacer(minLength: 12)

            Text("Names, technical terms, or words Jot mishears.")
                .font(.custom(JotType.frauncesItalicText, size: 15))
                .foregroundStyle(Color.jotMute)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .background(JotDesign.background.ignoresSafeArea())
        .onAppear {
            // Microhop so the sheet's presentation transition has settled
            // before we focus — without this the keyboard occasionally
            // animates in twice on first present.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                focused = true
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        ZStack {
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .font(.system(size: 16))
                .foregroundStyle(Color.jotInk)
                .frame(minHeight: 44)
                .accessibilityLabel("Cancel")

                Spacer()

                Button {
                    saveAndDismiss()
                } label: {
                    Text("Save")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canSave ? Color.jotAccent : Color.jotMuteWeak)
                        .frame(minHeight: 44)
                }
                .disabled(!canSave)
                .accessibilityLabel("Save term")
            }

            Text("New term")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Big centered field

    @ViewBuilder
    private var field: some View {
        // System TextField with `.tint(Color.jotRecord)` to color the
        // built-in caret red so it stays visible at the correct insertion
        // point as the user types. Previously we hand-rolled a blinking
        // red caret over a `.tint(.clear)` TextField, but that caret only
        // rendered while the field was empty — once the user typed one
        // character, the caret disappeared entirely. Routing through the
        // system caret keeps the red affordance through every typing
        // position with no manual blink timer.
        HStack(spacing: 0) {
            TextField("", text: $term, prompt: nil)
                .focused($focused)
                .font(.custom(JotType.frauncesRegular, size: 22))
                .foregroundStyle(Color.jotInk)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(false)
                .submitLabel(.done)
                .onSubmit { saveAndDismiss() }
                .tint(Color.jotRecord)
                .accessibilityLabel("Term")
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 60)
        .padding(.horizontal, 32)
    }

    // MARK: - Save

    private func saveAndDismiss() {
        guard canSave else { return }
        // `addBlankTerm()` returns a fresh row already appended to the
        // store; we then update its text so the file-write reflects the
        // user-entered string. This routes through the exact same
        // persistence path as the inline Edit-mode row, preserving the
        // `rebuildVocabulary` hook on save.
        let new = VocabularyStore.shared.addBlankTerm()
        VocabularyStore.shared.update(id: new.id, text: trimmed, aliases: [])
        dismiss()
    }
}

#Preview {
    AddVocabularyTermSheet()
}
