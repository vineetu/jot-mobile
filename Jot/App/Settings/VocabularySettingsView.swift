import JotVocabCore
import SwiftUI

/// Vocabulary settings pane — list of user-curated terms that the
/// on-device CTC rescorer will prefer during transcription.
///
/// Phase 5 reskin (mockup 16): editorial chrome on top of the same
/// persistence + boost-model wiring that shipped in commit `197a5b4`.
/// Sections render inside `GlassCard(.regular)` groups and the title
/// bar stays the standard nav title. The inline blue "+ Add Term" row
/// at the bottom of the Terms section is the single add path.
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

            // Single add path — the visible blue "+ Add Term" row.
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
            VStack(alignment: .leading, spacing: 6) {
                if store.lastSaveError != nil {
                    Label("Couldn't save changes to this device — they may be lost. Try again.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                // Copy updated 2026-07-13 (3-option ask): related terms like
                // "Claude" + "Claude Code" now COEXIST — when both fit, Jot asks
                // which one you meant — so the old "avoid sound-alike terms"
                // warning is gone. The casing tip replaces it (a term's exact
                // casing is inserted verbatim; a lowercase term would "correct"
                // properly-cased text the wrong way — seen in the owner's logs).
                Text("Helps Jot recognize names, technical terms, and words it tends to mishear. The list stays on your iPhone. Type each term exactly as you want it written — capitalization included. Related terms like \"Claude\" and \"Claude Code\" can coexist; when both fit, Jot asks which one you meant.")
            }
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
        // NOT "not downloaded" as a bare negative — terms ARE being corrected
        // without it now (features.md §8.9). The old label read as "this feature
        // is off", which is no longer true.
        case .notDownloaded: return "Terms working — boost model not downloaded"
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
            return "Downloading the vocabulary boost model (~99 MB). Keep Jot open; boosting starts as soon as it lands."
        case .notDownloaded:
            // On a stripped build (or after an iCloud restore, which excludes
            // the model from backup) the scorer downloads once, on demand — it
            // is NOT bundled anymore.
            //
            // Boosting NO LONGER WAITS on it (features.md §8.9): terms are
            // matched against the finished transcript with no model at all. The
            // previous copy — "Vocabulary boosting needs a one-time ~99 MB model
            // download" — became false the moment that shipped, and it told the
            // user the feature was dead while it was in fact working.
            return "Your terms are already being corrected. This one-time ~99 MB download also lets Jot recognise them while it listens, which catches more."
        case .failed:
            return "Your terms are still being corrected without this model — it only adds recognition while Jot listens. Retry below; if it still fails, check your internet."
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
            // Download-if-absent THEN load. On a healthy bundled install the
            // files are already on disk so this is a pure load; on a stripped
            // build it pulls the ~99 MB scorer first (coalesced with the B1
            // launch auto-trigger via the shared download gate).
            _ = try await CtcModelCache.shared.downloadAndLoad()
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
            Text("Tap + Add Term below to start.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .listRowBackground(Color.clear)
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

    /// Returns a binding that reads from the store and writes the term's TEXT
    /// through `update(id:text:)` — a plain list write, so every keystroke is
    /// persisted (a rename; the term's pairs go with it). Sounds-likes never
    /// write through here: the row's chips call `VocabularyLearning.apply`.
    private func binding(for id: VocabTerm.ID) -> Binding<VocabTerm> {
        Binding(
            get: { store.terms.first(where: { $0.id == id }) ?? VocabTerm(text: "") },
            set: { newValue in
                store.update(id: id, text: newValue.text)
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

    /// Draft for the "add a misheard form…" field. Committed on return/blur
    /// only — the row's binding writes through to `VocabularyStore.save()`,
    /// which rebuilds the CoreML rescorer, so a per-keystroke alias write would
    /// rebuild it once per character. (The comma-separated editor this replaced
    /// did exactly that, and needed a draft/round-trip dance to keep a comma
    /// from being eaten mid-type; chips remove both problems.)
    @State private var newAliasDraft: String = ""
    @FocusState private var aliasFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                TextField("Term", text: $term.text)
                    .font(.system(size: 16))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .focused(focusedID, equals: rowID)

            }
            // The warning is WRITTEN under the term as it's typed (an icon's
            // `.help` tooltip never shows on iPhone, so the reason was invisible).
            if let warning = warningMessage {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // "Sounds like" (aliases) — VISIBLE + editable (owner ask,
            // 2026-07-14; round-2 review flagged hidden aliases as unsafe:
            // Find & Replace / correction teaching writes them, and an
            // unwanted one silently changes future dictations).
            //
            // Shown for EVERY non-empty term, not only ones that already have
            // aliases (owner, 2026-08-31: the line "doesn't look like it's
            // editable"). Each alias is a deletable chip and the trailing field
            // is the add affordance, so the row reads as an input instead of a
            // caption — and it matches how the teaching sheet talks about the
            // same list.
            if !isBlank {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sounds like")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    FlowLayout(spacing: 6, lineSpacing: 4) {
                        // Indexed rather than keyed on the alias itself: a file
                        // written by an older build can hold exact duplicates,
                        // which would collide as identities.
                        ForEach(Array(term.aliases.enumerated()), id: \.offset) { index, alias in
                            aliasChip(alias, at: index)
                        }
                        // A FIXED width, and chip-shaped chrome instead of
                        // `.roundedBorder`. `FlowLayout` sizes each subview by
                        // proposing the full line width, and a TextField answers
                        // that proposal with all of it — so a `minWidth` field
                        // reported a full-width size, always wrapped onto its own
                        // line, and tripled the height of every row in the list.
                        // A fixed frame answers the proposal with 150 regardless,
                        // which is what lets it flow inline beside the chips (as
                        // the Atlas vocab-list screen shows it), and the padding
                        // here matches `aliasChip`'s so the two sit on one line.
                        TextField("add a misheard form…", text: $newAliasDraft)
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)
                            .frame(width: 150)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.35), lineWidth: 0.8)
                            )
                            .focused($aliasFieldFocused)
                            .onSubmit(commitNewAlias)
                            .accessibilityLabel("Add a misheard form for \(term.text)")
                    }
                }
                .padding(.bottom, 4)
                // Commit on blur as well as on return, so a typed form isn't
                // lost by tapping elsewhere.
                .onChange(of: aliasFieldFocused) { _, focused in
                    if !focused { commitNewAlias() }
                }
            }

        }
        .frame(minHeight: 44)
    }

    private var isBlank: Bool {
        term.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func aliasChip(_ alias: String, at index: Int) -> some View {
        HStack(spacing: 3) {
            // A mishearing can be a whole phrase, and the add-field takes
            // pastes — an unbounded chip wraps to several lines and swallows
            // the row. Middle truncation keeps both ends, which is what makes
            // a long alias recognizable at a glance.
            Text(alias)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Button {
                removeAlias(at: index)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove sounds-like \(alias)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.15)))
    }

    /// A sounds-like typed here is a correction ("when I say this, write
    /// that") and deleting one forgets it — both go through the one learning
    /// path by this row's id (Learn from Corrections), not the row's plain
    /// per-keystroke text write. The list's own scrub (`cleanEntry`) keeps
    /// ":" / "," out of the file; a duplicate (any casing) is a no-op add.
    private func commitNewAlias() {
        let typed = newAliasDraft
        newAliasDraft = ""
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let correction = Correction.correct(
            heard: typed, term: term.text, userCasing: true, termID: rowID)
        Task { @MainActor in
            // Put the draft back when the list refused it (too long, or the
            // file is unreadable), so the typing isn't silently lost.
            if case .rejected = await VocabularyLearning.shared.apply(correction).outcome,
               newAliasDraft.isEmpty {
                newAliasDraft = typed
            }
        }
    }

    private func removeAlias(at index: Int) {
        guard term.aliases.indices.contains(index) else { return }
        let correction = Correction.forget(heard: term.aliases[index], term: term.text, termID: rowID)
        Task { @MainActor in await VocabularyLearning.shared.apply(correction) }
    }

    /// "Too short" for two characters or fewer (the corrector and spotter skip
    /// them), otherwise the shared `VocabularyHygiene` warning over the active
    /// dictation language's everyday-word list — the same rule Mac and Windows
    /// show: a term whose first word is an everyday word, or (English) opens
    /// with one ("And…" in "Andalamma"), is easily mixed up with ordinary
    /// speech.
    private var warningMessage: String? {
        let t = term.text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        if t.count <= 2 {
            return "Too short — terms under 3 characters are skipped to avoid false replacements."
        }
        return JotVocabCore.VocabularyHygiene.warning(
            for: t,
            commonWords: AppVocabCore.activeCommonWords(),
            language: LanguageChoice.current.correctorLanguageCode
        )?.message
    }
}
