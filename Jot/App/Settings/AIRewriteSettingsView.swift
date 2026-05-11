import SwiftUI

/// Top-level AI Rewrite settings page. Reached from `SettingsView`'s
/// "AI Rewrite" navigation row. Composes three sections in order:
///
/// 1. Master toggle (single row, OFF by default).
/// 2. Engine state rows for Phi-4 mini (download / loading / ready / error
///    + delete-and-redownload). Single-provider — the prior engine picker
///    between Phi-4, Apple Intelligence, and Qwen has been collapsed.
/// 3. Saved prompts list with add/edit/delete/reorder.
///
/// All cross-process state (the master toggle and prompts list) reads/writes
/// through `AppGroup` accessors so the keyboard extension sees the same
/// values the main app's settings UI writes.
struct AIRewriteSettingsView: View {

    /// Provider-agnostic UI adapter wrapping the currently-resolved
    /// `LLMClient` (Phi-4 mini via MLX). The adapter surfaces a
    /// synchronous, SwiftUI-`@Observable` `observableStatus` mirror of
    /// the protocol's `async` `status`, plus
    /// `warm()` / `cancelDownload()` / `evict()` / `deleteModel()`
    /// shortcuts that forward into the concrete client.
    ///
    /// Resolved on `.onAppear` so the factory's lazy build runs before
    /// we capture the reference. `nil` during AI-rewrite-OFF / first
    /// appear before `.onAppear`.
    @State private var clientAdapter: LLMClientUIAdapter?

    /// Master toggle. Mirrors `AppGroup.aiRewriteEnabled` — read on appear,
    /// written back via `.onChange`.
    @State private var aiRewriteEnabled: Bool = AppGroup.aiRewriteEnabled

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
            SavedPromptStore.seedIfNeeded()
            reloadPrompts()
            // Resolve the live client through the factory and wrap it in a
            // provider-agnostic adapter. Capturing the adapter here gives
            // SwiftUI a stable `@Observable` to subscribe to. AI-rewrite OFF
            // still resolves the adapter so the engine row renders the
            // correct state immediately on master-toggle ON — but we do NOT
            // auto-trigger the download in that case (see opt-in gate below).
            rebuildAdapter()
            // Auto-warm gated on the master toggle. Without this gate, a
            // user who opens AI Rewrite settings just to look around would
            // accidentally start a 2.4 GB download on first appear. When
            // the toggle is ON and the weights aren't on disk, this
            // triggers the download and the `.downloading` UI takes over.
            // When ON and the weights are already on disk, status quickly
            // flips to `.ready`.
            if aiRewriteEnabled,
               let adapter = clientAdapter,
               case .notReady = adapter.observableStatus {
                triggerDownload()
            }
        }
        .onDisappear {
            // Stop the adapter's polling task so we don't keep reading
            // the underlying client's `status` after the screen goes
            // off-window. Re-installed by the next `.onAppear` →
            // `rebuildAdapter` → `start()`.
            clientAdapter?.stop()
        }
        .onChange(of: aiRewriteEnabled) { _, newValue in
            AppGroup.aiRewriteEnabled = newValue
            if newValue {
                // Master-toggle ON: kick off the download if weights aren't
                // already on disk. The user just opted in — that's the
                // explicit consent we were waiting for in `.onAppear`'s
                // gated branch.
                if let adapter = clientAdapter,
                   case .notReady = adapter.observableStatus {
                    triggerDownload()
                }
            } else {
                // Master-toggle OFF mid-download: stop any in-flight
                // download/warm immediately. Without this, the engine
                // section greys out as soon as the toggle flips, but
                // the underlying download keeps eating bandwidth and
                // bytes-on-disk with no UI path to cancel it (the row's
                // Cancel button lives inside the now-disabled section).
                // Routes through the adapter's `cancelDownload()`,
                // which calls `Phi4Client.cancelDownload()` — same
                // path the explicit Cancel button uses.
                cancelDownload()
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
            // Single-provider section header row: identifies the engine
            // without offering alternatives.
            Label {
                Text(Self.phi4Copy.name)
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Engine: \(Self.phi4Copy.name)")

            phi4StateRows
        } header: {
            Text("AI rewrite model")
        } footer: {
            Text("Runs on-device via MLX (Apple Silicon GPU). Requires a one-time download (~2.4 GB) over Wi-Fi.")
        }
    }

    /// Display copy for the Phi-4 rewrite model row.
    private static let phi4Copy = (name: "Phi-4 mini (Microsoft, MLX)", size: "Download (~2.4 GB)")

    @ViewBuilder
    private var phi4StateRows: some View {
        statusRows(
            displayName: Self.phi4Copy.name,
            sizeCopy: Self.phi4Copy.size,
            downloadButtonTitle: "Download Phi-4 mini (~2.4 GB)"
        )
    }

    /// Shared status-row renderer. Driven entirely by
    /// `clientAdapter.observableStatus`. Defaults to `.notReady` when the
    /// adapter hasn't been resolved yet (AI-rewrite OFF, or first appear
    /// before `.onAppear` fires). SwiftUI will diff and re-render once
    /// the adapter is set.
    @ViewBuilder
    private func statusRows(
        displayName: String,
        sizeCopy: String,
        downloadButtonTitle: String
    ) -> some View {
        let currentStatus: LLMClientStatus = clientAdapter?.observableStatus ?? .notReady
        switch currentStatus {
        case .notReady:
            Button {
                triggerDownload()
            } label: {
                Label(downloadButtonTitle, systemImage: "arrow.down.circle")
            }
            .accessibilityLabel(downloadButtonTitle)

            Text(sizeCopy)
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
            .accessibilityLabel("Downloading \(displayName), \(Int((fraction * 100).rounded())) percent")
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
            .accessibilityLabel("Loading \(displayName)")

        case .ready:
            Label {
                Text("Ready")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            .accessibilityLabel("\(displayName) is ready")

            Button {
                deleteModel()
            } label: {
                Text("Free memory")
            }
            .accessibilityLabel("Free \(displayName) memory")

        case .evicted:
            // Evicted: in-memory weights have been dropped (manually via
            // "Free memory" or automatically on memory pressure), but
            // the HF cache on disk is intact — `warm()` reloads without
            // re-downloading.
            Label {
                Text("Unloaded — reload to use")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("\(displayName) is unloaded")

            Button {
                triggerDownload()
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("Reload \(displayName)")

        case .error(let message):
            Label {
                Text(message)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("\(displayName) error: \(message)")

            Button {
                triggerDownload()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("Retry \(displayName) download")
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

    /// Resolve the factory's current `LLMClient` and wrap it in a fresh
    /// `LLMClientUIAdapter`. Tears down the previous adapter's polling
    /// task before the swap so we don't leak two pollers on the same
    /// view.
    private func rebuildAdapter() {
        clientAdapter?.stop()
        let client = LLMClientFactory.shared.client()
        let adapter = LLMClientUIAdapter(client: client)
        adapter.start()
        clientAdapter = adapter
    }

    /// Kick off the current adapter's `warm()` lifecycle. This drives
    /// download → load → ready for the Phi-4 weights via the MLX bridge.
    private func triggerDownload() {
        if clientAdapter == nil {
            rebuildAdapter()
        }
        clientAdapter?.warm()
    }

    /// Cancel an in-flight download / warm. Idempotent at the adapter
    /// layer — the underlying client is the source of truth.
    private func cancelDownload() {
        clientAdapter?.cancelDownload()
    }

    /// Drop in-memory weights. Phi-4 weights live in the HuggingFace
    /// cache directory managed by the MLX bridge; this is effectively a
    /// "free memory" affordance — the on-disk cache persists so the
    /// next `warm()` doesn't re-download.
    private func deleteModel() {
        clientAdapter?.deleteModel()
    }
}

#Preview {
    NavigationStack {
        AIRewriteSettingsView()
    }
}
