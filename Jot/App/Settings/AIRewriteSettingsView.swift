import SwiftUI

/// Top-level AI Rewrite settings page. Reached from `SettingsView`'s
/// "AI Rewrite" navigation row. Composes three sections in order:
///
/// 1. Master toggle (single row, OFF by default).
/// 2. Engine picker + per-engine inline state (Phi-4 download/loading/ready,
///    Apple Intelligence built-in caption).
/// 3. Saved prompts list with add/edit/delete/reorder.
///
/// All cross-process state (the master toggle, picker, and prompts list)
/// reads/writes through `AppGroup` accessors so the keyboard extension sees
/// the same values the main app's settings UI writes.
struct AIRewriteSettingsView: View {

    /// Live `@Observable` Phi-4 client surfaced through the factory. We hold
    /// it directly (not the `LLMClient` protocol) because the UI needs the
    /// `observableStatus` synchronous getter and the `cancelDownload()` /
    /// `evict()` lifecycle hooks — protocol-level `status` is `async` and
    /// returns a snapshot, not a SwiftUI-observable surface.
    ///
    /// Resolved on `.onAppear` so the factory's provider-switch logic
    /// (Settings → AppGroup → factory rebuild) runs before we capture the
    /// reference. The Apple Intelligence branch doesn't render this row,
    /// so a `nil` resolver during AI-rewrite-off / FM-selected states is
    /// fine.
    @State private var phi4Client: Phi4Client?

    /// Track an in-flight warm Task so `cancelDownload()` UI hooks can
    /// cancel it. The Phi4Client ALSO holds its own internal task for
    /// the same purpose; we keep this here for SwiftUI-side lifecycle
    /// (e.g. cancel-on-disappear future work). Today both paths converge
    /// on `Phi4Client.cancelDownload()`.
    @State private var warmTask: Task<Void, Error>?

    /// Master toggle. Mirrors `AppGroup.aiRewriteEnabled` — read on appear,
    /// written back via `.onChange`.
    @State private var aiRewriteEnabled: Bool = AppGroup.aiRewriteEnabled

    /// Selected provider. `"phi4"` or `"appleIntelligence"`. Written back
    /// to AppGroup on `.onChange` so the keyboard observes the same
    /// selection the user just made in the picker.
    ///
    /// NOTE: brief specifies `"fm"` for the alternate, but the parallel
    /// `LLMClientFactory` lands `LLMProvider.appleIntelligence` with raw
    /// value `"appleIntelligence"`. We align with the factory so the
    /// AppGroup write round-trips through `LLMProvider(rawValue:)`. Flag
    /// for orchestrator if the brief is the source of truth instead.
    @State private var selectedProvider: String = AppGroup.aiRewriteProvider

    /// Saved-prompt list, kept in `@State` so SwiftUI diffs row-level changes
    /// without rebuilding the list on every settings appearance. Reloaded
    /// from `SavedPromptStore` on appear and after add/edit/delete/reorder
    /// callbacks from the sheet.
    @State private var prompts: [SavedPrompt] = []

    /// Currently presented sheet. `.add` shows the empty form; `.edit`
    /// pre-populates from the supplied row.
    @State private var sheet: SheetMode?

    /// Pending swipe-to-delete confirmation target. Bound to the alert.
    @State private var deletionTarget: SavedPrompt?

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
        Form {
            masterToggleSection
            if aiRewriteEnabled {
                engineSection
                promptsSection
            } else {
                // Render dimmed/disabled sections so the user gets a preview
                // of what flipping the master toggle ON unlocks. SwiftUI's
                // `.disabled(true)` plus `.opacity(0.5)` matches the system
                // pattern (compare iOS Settings → Sounds & Haptics when
                // silent mode is on).
                engineSection
                    .disabled(true)
                    .opacity(0.5)
                promptsSection
                    .disabled(true)
                    .opacity(0.5)
            }
        }
        .navigationTitle("AI Rewrite")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            // EditButton is only meaningful on the prompts list, but the
            // `Form` only has one editable list, so a single nav-bar
            // EditButton is enough. Hide when master toggle is off.
            if aiRewriteEnabled {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .sheet(item: $sheet) { mode in
            switch mode {
            case .add:
                EditPromptSheet(prompt: nil) {
                    reloadPrompts()
                }
            case .edit(let prompt):
                EditPromptSheet(prompt: prompt) {
                    reloadPrompts()
                }
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
            // Re-sync from AppGroup in case the keyboard mutated something
            // while the sheet was off-screen.
            aiRewriteEnabled = AppGroup.aiRewriteEnabled
            selectedProvider = AppGroup.aiRewriteProvider
            SavedPromptStore.seedIfNeeded()
            reloadPrompts()
            // Resolve the live Phi-4 client through the factory. The factory
            // rebuilds on provider change; capturing the reference here gives
            // SwiftUI a stable `@Observable` to subscribe to. Cast is safe —
            // when `currentProvider == .phi4`, the factory returns a
            // `Phi4Client`. AI-rewrite OFF or FM-selected leaves
            // `phi4Client == nil`.
            if AppGroup.aiRewriteProvider == "phi4" {
                phi4Client = LLMClientFactory.shared.client() as? Phi4Client
            } else {
                phi4Client = nil
            }
            // Auto-warm: if weights are on disk, status will quickly flip to .ready.
            // If weights aren't on disk, the .downloading UI takes over and shows real
            // download progress. Skip if status is already non-.notReady (already warmed
            // or in progress) or if Apple Intelligence is the selected provider.
            if AppGroup.aiRewriteProvider == "phi4",
               let client = phi4Client,
               case .notReady = client.observableStatus {
                triggerDownload()
            }
        }
        .onChange(of: aiRewriteEnabled) { _, newValue in
            AppGroup.aiRewriteEnabled = newValue
        }
        .onChange(of: selectedProvider) { _, newValue in
            AppGroup.aiRewriteProvider = newValue
            // Re-resolve the cached Phi-4 client when the user flips
            // engines. The factory will rebuild on the next `client()`
            // call (it caches by provider).
            if newValue == "phi4" {
                phi4Client = LLMClientFactory.shared.client() as? Phi4Client
            } else {
                phi4Client = nil
            }
            if newValue == "phi4",
               let client = phi4Client,
               case .notReady = client.observableStatus {
                triggerDownload()
            }
        }
    }

    // MARK: - Sections

    private var masterToggleSection: some View {
        Section {
            Toggle(isOn: $aiRewriteEnabled) {
                Label("Enable AI Rewrite", systemImage: "wand.and.stars")
            }
            .accessibilityLabel("Enable AI Rewrite")
        } header: {
            Text("AI Rewrite")
        } footer: {
            Text("Lets the keyboard's Magic button rewrite selected text using an on-device language model. Off by default.")
        }
    }

    @ViewBuilder
    private var engineSection: some View {
        Section {
            Picker("Engine", selection: $selectedProvider) {
                Text("Apple Intelligence (recommended)").tag("appleIntelligence")
                Text("Phi-4 Mini").tag("phi4")
            }
            .pickerStyle(.inline)
            .labelsHidden()
            .accessibilityLabel("Engine")

            if selectedProvider != "appleIntelligence" {
                phi4StateRows
            } else {
                Label {
                    Text("Built-in (no download required)")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "apple.logo")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Apple Intelligence is built into iOS — no download required.")
            }
        } header: {
            Text("Engine")
        }
    }

    @ViewBuilder
    private var phi4StateRows: some View {
        // Default to `.notReady` when the Phi-4 client hasn't been resolved
        // yet (AI rewrite OFF, or first appear before `.onAppear` fires).
        // SwiftUI will diff and re-render once `phi4Client` is set.
        let currentStatus: LLMClientStatus = phi4Client?.observableStatus ?? .notReady
        switch currentStatus {
        case .notReady:
            Button {
                triggerDownload()
            } label: {
                Label("Download Phi-4 Mini", systemImage: "arrow.down.circle")
            }
            .accessibilityLabel("Download Phi-4 Mini")

            Text("Download (~2.4 GB)")
                .font(.footnote)
                .foregroundStyle(.secondary)

        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Downloading Phi-4 Mini, \(Int((fraction * 100).rounded())) percent")
            Button(role: .destructive) {
                cancelDownload()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .accessibilityLabel("Cancel download")

        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading Phi-4 Mini")

        case .ready:
            Label {
                Text("Ready")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .accessibilityLabel("Phi-4 Mini is ready")

            Button(role: .destructive) {
                deleteModel()
            } label: {
                Text("Delete model")
            }
            .accessibilityLabel("Delete Phi-4 Mini model")

        case .evicted:
            HStack(spacing: 8) {
                ProgressView()
                Text("Loading…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reloading Phi-4 Mini")

        case .error(let message):
            Label {
                Text(message)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Phi-4 Mini error: \(message)")

            Button {
                triggerDownload()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("Retry Phi-4 Mini download")
        }
    }

    @ViewBuilder
    private var promptsSection: some View {
        Section {
            ForEach(prompts) { prompt in
                Button {
                    sheet = .edit(prompt)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prompt.name)
                            .foregroundStyle(.primary)
                        Text(prompt.systemPrompt)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Edit prompt \(prompt.name)")
                .accessibilityHint("Opens the prompt editor")
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deletionTarget = prompt
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onMove { source, destination in
                SavedPromptStore.reorder(source: source, destination: destination)
                reloadPrompts()
            }
        } header: {
            HStack {
                Text("Prompts")
                Spacer()
                Button {
                    sheet = .add
                } label: {
                    Image(systemName: "plus")
                        .font(.body.weight(.semibold))
                }
                .accessibilityLabel("Add prompt")
                // Headers render in a subdued style — match by tinting to
                // the accent color so the affordance reads as interactive.
                .tint(.accentColor)
                // Header buttons inherit `.textCase(.uppercase)` from the
                // section style; suppress so the SF Symbol renders cleanly.
                .textCase(nil)
            }
        }
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

    /// Kick off the Phi-4 download + load.
    private func triggerDownload() {
        // Lazy-resolve in case `.onAppear` hasn't fired yet (deep-link
        // entry or re-entry after a provider flip).
        if phi4Client == nil {
            phi4Client = LLMClientFactory.shared.client() as? Phi4Client
        }
        guard let client = phi4Client else { return }
        warmTask?.cancel()
        warmTask = Task {
            try await client.warm()
        }
    }

    /// Cancel an in-flight download. Idempotent; the client itself is the
    /// source of truth for the warm Task lifecycle.
    private func cancelDownload() {
        warmTask?.cancel()
        warmTask = nil
        phi4Client?.cancelDownload()
    }

    /// Evict in-memory weights. On-disk HF cache purge is intentionally
    /// NOT done here — the HF snapshot path under `LLMModelFactory`'s
    /// `#hubDownloader()` cache root isn't a stable public API surface,
    /// and a wrong-path purge would silently break the next download.
    /// `evict()` is sufficient to free MLX RAM; the on-disk weights can
    /// be reclaimed by the OS via the standard "Delete app and reinstall"
    /// path. Tracked as TODO for a follow-up that exposes the snapshot
    /// URL through the factory.
    private func deleteModel() {
        guard let client = phi4Client else { return }
        Task {
            await client.evict()
        }
    }
}

#Preview {
    NavigationStack {
        AIRewriteSettingsView()
    }
}
