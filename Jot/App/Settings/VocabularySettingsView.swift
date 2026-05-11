import SwiftUI

/// Vocabulary settings pane — list of user-curated terms that the
/// on-device CTC rescorer will prefer during transcription.
///
/// iOS-native adaptation of `jot/Sources/Vocabulary/VocabularyPane.swift`:
///   - SwiftUI `Form` + `List` instead of macOS-style grouped form.
///   - Swipe-to-delete + EditButton instead of hover-to-reveal trash icon.
///   - "Add Term" appears as a row at the bottom of the list.
///   - The desktop pane's `Japanese-primary lockout` and `InfoPopoverButton`
///     are skipped — the mobile app doesn't ship a JA model and uses
///     section footers for context instead of popovers.
///   - The "Boost model" download section is hidden in this milestone:
///     the on-device rescorer wiring (download CTC 110M bundle + load
///     `VocabularyRescorer` + integrate into `TranscriptionService`) is
///     Phase B; today the list is persistence-only so the user can
///     validate the shape and start curating their terms.
/// Boost-model download state, surfaced to the pane so the user can
/// see what's happening. Pre-installed state lives in
/// `CtcModelCache.shared.isCached` — this enum captures the
/// UI-visible transitions around it.
enum BoostModelStatus: Equatable {
    case notDownloaded
    case downloading
    case ready
    case failed(String)
}

struct VocabularySettingsView: View {
    @State private var store = VocabularyStore.shared
    @State private var boostModelStatus: BoostModelStatus = .notDownloaded
    @FocusState private var focusedID: VocabTerm.ID?

    var body: some View {
        Form {
            masterToggleSection
            boostModelSection
            termsSection
        }
        .navigationTitle("Vocabulary")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if !store.terms.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .onAppear {
            // Re-load from disk in case the user edited the file externally
            // (Files app, iCloud Drive, etc.) since the last appearance.
            store.load()
            refreshBoostModelStatus()
            // Late-arrival hook for the Option A flow: if the boost
            // model finished downloading via the setup wizard or
            // Settings tap WHILE the user was elsewhere, picking up
            // the now-cached state on appear AND auto-preparing the
            // rescorer (when the master toggle is on) closes the
            // race where toggle-enable preceded boost-download
            // completion. Without this, the pane would show "Ready"
            // for the boost but the rescorer would silently not be
            // prepared until the user toggled off/on or tapped
            // Download in the boost section.
            if store.isEnabled, CtcModelCache.shared.isCached {
                Task { await prepareRescorerIfPossible() }
            }
        }
        .onChange(of: store.isEnabled) { _, enabled in
            if enabled {
                Task { await prepareRescorerIfPossible() }
            } else {
                Task { await VocabularyRescorerHolder.shared.unload() }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var masterToggleSection: some View {
        Section {
            Toggle(
                "Enable vocabulary boosting",
                isOn: Binding(
                    get: { store.isEnabled },
                    set: { store.isEnabled = $0 }
                )
            )
        } footer: {
            Text(headerSubtext)
        }
    }

    private var headerSubtext: String {
        store.isEnabled
            ? "Jot will prefer the terms below when transcribing. Add product names, proper nouns, and jargon you want spelled a specific way."
            : "When on, Jot prefers these terms during transcription. Edit the list anytime; boosting applies on your next recording."
    }

    @ViewBuilder
    private var termsSection: some View {
        Section {
            if store.terms.isEmpty {
                emptyStateView
            } else {
                ForEach(store.terms) { term in
                    VocabRow(
                        term: binding(for: term.id),
                        focusedID: $focusedID,
                        rowID: term.id
                    )
                }
                .onDelete { offsets in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        store.delete(at: offsets)
                    }
                }
                .onMove { source, destination in
                    store.move(fromOffsets: source, toOffset: destination)
                }
            }

            Button {
                addTerm()
            } label: {
                Label("Add Term", systemImage: "plus")
            }
        } header: {
            HStack {
                Text("Terms")
                Spacer()
                if !store.terms.isEmpty {
                    Text("\(store.terms.count)")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            // Two-character warning happens inline per-row; this footer
            // is the prose version + the file-location hint for users
            // who want to know where their list lives.
            Text("Each term should be at least 3 characters. The list lives in this device's app data; reset Jot to clear it.")
        }
    }

    // MARK: - Boost model

    @ViewBuilder
    private var boostModelSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(boostModelHeadline)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(boostModelHeadlineColor)
                    Text(boostModelSubtext)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                boostModelAction
            }
            .padding(.vertical, 2)
        } header: {
            Text("Boost model")
        }
    }

    private var boostModelHeadline: String {
        switch boostModelStatus {
        case .ready:         return "Boost model ready"
        case .downloading:   return "Downloading boost model…"
        case .notDownloaded: return "Boost model not downloaded"
        case .failed(let m): return "Boost unavailable — \(m)"
        }
    }

    private var boostModelHeadlineColor: Color {
        switch boostModelStatus {
        case .failed: return .red
        default:      return .primary
        }
    }

    private var boostModelSubtext: String {
        switch boostModelStatus {
        case .ready:
            return "Parakeet CTC 110M on this iPhone. Boosting runs on the Neural Engine; no audio leaves the device."
        case .downloading:
            return "≈100 MB from Hugging Face over Wi-Fi. You can keep using Jot while it finishes — boosting activates when it's ready."
        case .notDownloaded:
            return "≈100 MB. Normally downloaded with the speech model — tap if it didn't land."
        case .failed:
            return "The rest of Jot keeps working — only vocabulary boosting needs this bundle. Retry below; if it still fails, check your internet."
        }
    }

    @ViewBuilder
    private var boostModelAction: some View {
        switch boostModelStatus {
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.green)
                .accessibilityLabel("Ready")
        case .downloading:
            ProgressView().controlSize(.small)
        case .notDownloaded, .failed:
            Button("Download") {
                Task { await downloadBoostModel() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func refreshBoostModelStatus() {
        // Guard against drift: if the cache was deleted externally
        // while the pane was open, reflect that so the user can
        // re-download instead of the UI claiming `.ready` and silently
        // failing on every record.
        boostModelStatus = CtcModelCache.shared.isCached ? .ready : .notDownloaded
    }

    private func downloadBoostModel() async {
        boostModelStatus = .downloading
        do {
            _ = try await CtcModelCache.shared.ensureLoaded()
            boostModelStatus = .ready
            if store.isEnabled {
                await prepareRescorerIfPossible()
            }
        } catch {
            boostModelStatus = .failed(error.localizedDescription)
        }
    }

    private func prepareRescorerIfPossible() async {
        // Re-check the cache: `CtcModelCache.shared` may have been
        // invalidated by a concurrent path. Refresh UI state before
        // attempting to prepare, so a failed prepare leaves the user
        // on a correct "not downloaded" row instead of a stale "ready".
        guard let url = store.fileURL else { return }
        guard CtcModelCache.shared.isCached else {
            boostModelStatus = .notDownloaded
            return
        }
        do {
            try await VocabularyRescorerHolder.shared.prepare(vocabularyFileURL: url)
        } catch {
            boostModelStatus = .failed(error.localizedDescription)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "quote.bubble")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
                .padding(.top, 16)
            Text("No vocabulary yet.")
                .font(.subheadline.weight(.medium))
            Text("Add names and acronyms Jot should get right.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }

    // MARK: - Actions

    private func addTerm() {
        let new = store.addBlankTerm()
        // Focus lands inside the new row's TextField after SwiftUI
        // rebuilds the ForEach. A short runloop hop is enough for the
        // focus proxy to install.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            focusedID = new.id
        }
    }

    /// Returns a binding that reads from the store and writes through
    /// `update(id:text:aliases:)` so every keystroke is persisted
    /// without the row having to know about the store.
    private func binding(for id: VocabTerm.ID) -> Binding<VocabTerm> {
        Binding(
            get: { store.terms.first(where: { $0.id == id }) ?? VocabTerm(text: "") },
            set: { newValue in
                store.update(id: id, text: newValue.text, aliases: newValue.aliases)
            }
        )
    }
}

/// A single row in the Vocabulary pane: one tappable text field for the
/// term + inline warning glyph for footguns.
///
/// iOS-native simplification of `jot/Sources/Vocabulary/VocabRow.swift`:
///   - Drops the hover-to-reveal delete button (swipe-to-delete + the
///     toolbar EditButton both deliver the same affordance on iOS).
///   - The same warning heuristics ship verbatim (too-short term,
///     common-English watchlist).
private struct VocabRow: View {
    @Binding var term: VocabTerm
    var focusedID: FocusState<VocabTerm.ID?>.Binding
    let rowID: VocabTerm.ID

    var body: some View {
        HStack(spacing: 8) {
            TextField("Term", text: $term.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .focused(focusedID, equals: rowID)

            if let warning = warningMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .help(warning)
                    .accessibilityLabel(warning)
            }
        }
    }

    private var warningMessage: String? {
        let t = term.text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        if t.count <= 2 {
            return "Too short — terms under 3 characters are skipped to avoid false replacements."
        }
        if Self.commonEnglishWatchlist.contains(t) {
            return "Common English word — may cause false replacements in transcripts that use the word normally."
        }
        return nil
    }

    // Curated watchlist of common English words very likely to collide
    // with ordinary speech. Same shape as the desktop's list.
    private static let commonEnglishWatchlist: Set<String> = [
        "the", "and", "for", "that", "with", "this", "from", "have",
        "they", "will", "one", "all", "would", "their", "what", "out",
        "about", "which", "when", "make", "like", "time", "just", "him",
        "know", "take", "into", "year", "your", "good", "some", "could",
        "them", "see", "other", "than", "then", "now", "look", "only",
        "come", "over", "think", "also", "back", "after", "use", "two",
        "how", "our", "work", "first", "well", "way", "even", "new",
        "want", "any", "give", "day", "most", "very", "find", "thing",
        "tell", "say", "get", "made", "part", "yes", "yeah"
    ]
}
