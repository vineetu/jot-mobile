import SwiftUI

/// Single sheet that handles both add and edit flows for `SavedPrompt`. Pass
/// `nil` for the add flow, or an existing row for the edit flow. The
/// `onChange` closure is invoked after a successful save or delete so the
/// host page can reload its list from `SavedPromptStore`.
struct EditPromptSheet: View {
    let prompt: SavedPrompt?
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var systemPrompt: String = ""
    @State private var showDeleteConfirmation: Bool = false

    @FocusState private var nameFieldFocused: Bool

    private var isEditing: Bool { prompt != nil }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSystemPrompt: String {
        systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValid: Bool {
        !trimmedName.isEmpty
            && !trimmedSystemPrompt.isEmpty
            && trimmedName.count <= SavedPrompt.nameMaxLength
            && trimmedSystemPrompt.count <= SavedPrompt.systemPromptMaxLength
    }

    /// Threshold (in chars remaining) at which the live counter caption
    /// becomes visible. Avoids cluttering the form when the user is nowhere
    /// near the cap.
    private static let counterRevealThreshold: Int = 50

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFieldFocused)
                        .submitLabel(.next)
                        .accessibilityLabel("Prompt name")
                        .onChange(of: name) { _, newValue in
                            // Hard cap to the name limit — we still trim on
                            // save, but this stops the user from typing
                            // 200 chars and then being surprised the Save
                            // button is disabled.
                            if newValue.count > SavedPrompt.nameMaxLength {
                                name = String(newValue.prefix(SavedPrompt.nameMaxLength))
                            }
                        }
                    if shouldShowNameCounter {
                        Text("\(name.count) / \(SavedPrompt.nameMaxLength)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(name.count) of \(SavedPrompt.nameMaxLength) characters used")
                    }
                } header: {
                    Text("Name")
                }

                Section {
                    // `TextEditor` doesn't have a placeholder API; a `ZStack`
                    // with a fallback `Text` is the standard workaround.
                    ZStack(alignment: .topLeading) {
                        if systemPrompt.isEmpty {
                            Text("Instruction for the rewrite model…")
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.leading, 4)
                                .accessibilityHidden(true)
                        }
                        TextEditor(text: $systemPrompt)
                            .frame(minHeight: 140) // ~6 lines at default Dynamic Type
                            .accessibilityLabel("System prompt")
                            .onChange(of: systemPrompt) { _, newValue in
                                if newValue.count > SavedPrompt.systemPromptMaxLength {
                                    systemPrompt = String(newValue.prefix(SavedPrompt.systemPromptMaxLength))
                                }
                            }
                    }
                    if shouldShowSystemPromptCounter {
                        Text("\(systemPrompt.count) / \(SavedPrompt.systemPromptMaxLength)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(systemPrompt.count) of \(SavedPrompt.systemPromptMaxLength) characters used")
                    }
                } header: {
                    Text("System prompt")
                } footer: {
                    Text("This instruction is sent to the rewrite model along with the selected text.")
                }

                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete Prompt", systemImage: "trash")
                                .foregroundStyle(.red)
                        }
                        .accessibilityLabel("Delete this prompt")
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Prompt" : "New Prompt")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        saveAndDismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .alert(
                deleteAlertTitle,
                isPresented: $showDeleteConfirmation
            ) {
                Button("Delete", role: .destructive) {
                    deleteAndDismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("This can't be undone.")
            }
            .onAppear {
                if let existing = prompt {
                    name = existing.name
                    systemPrompt = existing.systemPrompt
                }
                if !isEditing {
                    nameFieldFocused = true
                }
            }
        }
    }

    // MARK: - Helpers

    private var shouldShowNameCounter: Bool {
        let remaining = SavedPrompt.nameMaxLength - name.count
        return remaining <= Self.counterRevealThreshold
    }

    private var shouldShowSystemPromptCounter: Bool {
        let remaining = SavedPrompt.systemPromptMaxLength - systemPrompt.count
        return remaining <= Self.counterRevealThreshold
    }

    private var deleteAlertTitle: String {
        if let existing = prompt {
            return "Delete \"\(existing.name)\"?"
        }
        return "Delete prompt?"
    }

    private func saveAndDismiss() {
        guard isValid else { return }
        if let existing = prompt {
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

    private func deleteAndDismiss() {
        guard let existing = prompt else { return }
        SavedPromptStore.delete(id: existing.id)
        onChange()
        dismiss()
    }
}

#Preview("Add") {
    EditPromptSheet(prompt: nil, onChange: {})
}

#Preview("Edit") {
    EditPromptSheet(prompt: SavedPrompt.defaultRewrite, onChange: {})
}
