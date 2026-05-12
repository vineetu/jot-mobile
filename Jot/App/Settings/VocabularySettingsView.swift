import SwiftUI

/// Vocabulary settings pane — list of user-curated terms that the
/// on-device CTC rescorer will prefer during transcription.
///
/// Phase 5 reskin (mockup 16): editorial chrome on top of the same
/// persistence + boost-model wiring that shipped in commit `197a5b4`.
/// Sections render inside `GlassCard(.regular)` groups, the title bar
/// stays the standard nav title, and a floating coral "+ Add term"
/// FAB at the bottom presents `AddVocabularyTermSheet`.
///
/// Preserved exactly from the previous implementation:
///   - `VocabularyStore.shared` is the persistence path (file-backed
///     `Application Support/Vocabulary/vocabulary.txt`).
///   - `BoostModelStatus` + `CtcModelCache.shared` integration.
///   - `VocabularyRescorerHolder.shared.prepare(...)` on master-toggle ON
///     and `unload()` on OFF.
///   - Auto-prepare-rescorer race-closer in `.onAppear`.
///   - Swipe-to-delete + drag-to-reorder via the existing `EditButton`.
///
/// Boost-model download state, surfaced to the pane so the user can
/// see what's happening.
enum BoostModelStatus: Equatable {
    case notDownloaded
    case downloading
    case ready
    case failed(String)
}

struct VocabularySettingsView: View {
    @State private var store = VocabularyStore.shared
    @State private var boostModelStatus: BoostModelStatus = .notDownloaded
    @State private var showAddSheet: Bool = false
    @FocusState private var focusedID: VocabTerm.ID?

    var body: some View {
        ZStack(alignment: .bottom) {
            Form {
                masterToggleSection
                boostModelSection
                termsSection
            }
            // The floating Add-term FAB hovers over the bottom of the list;
            // pad the Form so the last row + footer aren't tucked behind
            // the button on a long list.
            .safeAreaPadding(.bottom, 80)

            addTermFAB
                .padding(.bottom, 18)
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
        .sheet(isPresented: $showAddSheet) {
            AddVocabularyTermSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            // Re-load from disk in case the user edited the file externally
            // (Files app, iCloud Drive, etc.) since the last appearance.
            store.load()
            refreshBoostModelStatus()
            // Late-arrival hook for the Option A flow — see the original
            // VocabularySettingsView for the full race-closer rationale.
            // If the boost model finished downloading while the user was
            // elsewhere, auto-prepare the rescorer now so transcription
            // picks up the bias on the next dictation.
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

            // Edit-mode inline-add row, preserved for Edit-mode parity with
            // the previous implementation. The visible floating FAB is the
            // primary entry, but Edit-button reorder users get this fallback.
            Button {
                addInlineBlankTerm()
            } label: {
                Label("Add Term", systemImage: "plus")
            }
        } header: {
            HStack {
                Text(termsHeader)
                Spacer()
                if !store.terms.isEmpty {
                    Text("A to Z")
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Helps Jot recognize names, technical terms, and words it tends to mishear. The list stays on your iPhone.")
        }
    }

    private var termsHeader: String {
        store.terms.isEmpty ? "Terms" : "Terms · \(store.terms.count)"
    }

    // MARK: - Boost model

    @ViewBuilder
    private var boostModelSection: some View {
        Section {
            HStack(spacing: 12) {
                IconBox(symbol: "waveform", tint: Color.teal, size: 36)

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
        // Re-check the cache before attempting prepare — see original
        // VocabularySettingsView for the full rationale.
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
            Text("Tap + Add term to start.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
    }

    // MARK: - Add-term FAB

    /// Floating coral "+ Add term" button at the bottom of the list. Matches
    /// the `DictateFAB` shape (smaller — ~140pt wide). Tapping it presents
    /// the `AddVocabularyTermSheet`.
    @ViewBuilder
    private var addTermFAB: some View {
        Button {
            showAddSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                Text("Add term")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .frame(minHeight: 48)
            .padding(.horizontal, 24)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.jotAccent, Color.jotAccent.opacity(0.92)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
            )
            .shadow(color: Color.jotAccent.opacity(0.35), radius: 14, x: 0, y: 8)
            .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add term")
        .accessibilityHint("Opens the new-term sheet")
    }

    // MARK: - Actions

    /// Edit-mode inline add path — preserved from the original
    /// implementation for users who're already in Edit mode reordering.
    private func addInlineBlankTerm() {
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
                .font(.system(size: 16))
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
        .frame(minHeight: 44)
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
