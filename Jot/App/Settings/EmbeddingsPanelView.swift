#if JOT_APP_HOST
import SwiftData
import SwiftUI

/// Settings surface for on-device indexing.
///
/// The on-device classifier / category-seeding UI that previously lived here
/// was removed with the tagging feature. What remains is genuinely
/// embeddings-related: the kill-switch toggle for the indexer (default ON), an
/// indexed-chunk counter, and a one-shot **Rebuild search index** button that
/// re-embeds the whole corpus with the current model (used after a model
/// change — e.g. the move to EmbeddingGemma — or to force a fresh index).
///
/// The rebuild is a manual, foreground, cancellable pass with live progress;
/// background incremental backfill is handled separately by `EmbeddingBackfillTask`.
struct EmbeddingsPanelView: View {
    @State private var embeddingsEnabled: Bool = AppGroup.isEmbeddingsEnabled
    @State private var indexedChunkCount: Int = 0

    @State private var isRebuilding = false
    @State private var rebuildDone = 0
    @State private var rebuildTotal = 0
    @State private var rebuildTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            WallpaperBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    titleBlock
                    toggleCard
                    rebuildCard
                    statusFooter
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
        }
        .navigationTitle("Indexing")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            embeddingsEnabled = AppGroup.isEmbeddingsEnabled
            refreshCounts()
        }
        .onDisappear { rebuildTask?.cancel() }
        .onChange(of: embeddingsEnabled) { _, newValue in
            AppGroup.isEmbeddingsEnabled = newValue
            if newValue {
                EmbeddingBackfillTask.submitIfBacklog()
            }
        }
    }

    // MARK: - Layout

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("On-device indexing")
                .font(JotType.displaySerif(28))
                .foregroundStyle(Color.jotInk)
            Text("Indexes your dictations on-device for search and Ask.")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggleCard: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            HStack(alignment: .center, spacing: 14) {
                IconTile(
                    systemImage: "sparkles",
                    tint: Color.jotBlueTop,
                    shaded: Color.jotBlueBottom.opacity(0.15)
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("On-device indexing")
                        .font(JotType.rowTitle)
                        .tracking(-0.2)
                        .foregroundStyle(Color.jotPageInk)
                    Text(toggleSubline)
                        .font(JotType.rowSub)
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .lineSpacing(2)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: $embeddingsEnabled)
                    .labelsHidden()
                    .tint(Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255))
                    .accessibilityLabel("On-device indexing")
            }
            .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
    }

    private var rebuildCard: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 14) {
                    IconTile(
                        systemImage: "arrow.clockwise",
                        tint: Color.jotBlueTop,
                        shaded: Color.jotBlueBottom.opacity(0.15)
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Rebuild search index")
                            .font(JotType.rowTitle)
                            .tracking(-0.2)
                            .foregroundStyle(Color.jotPageInk)
                        Text("Re-embeds every dictation with the current model. Run once after an update; one-shot, on-device.")
                            .font(JotType.rowSub)
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .lineSpacing(2)
                    }
                    Spacer(minLength: 12)
                }

                if isRebuilding {
                    ProgressView(value: rebuildTotal > 0 ? Double(rebuildDone) / Double(rebuildTotal) : 0)
                        .tint(Color.jotBlueBottom)
                    HStack {
                        Text("\(rebuildDone) / \(rebuildTotal)")
                            .font(JotType.rowSub)
                            .foregroundStyle(Color.jotPageInkSecondary)
                        Spacer()
                        Button("Cancel") { rebuildTask?.cancel() }
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(Color.jotMute)
                    }
                } else {
                    Button {
                        startRebuild()
                    } label: {
                        Text("Rebuild now")
                            .font(.system(.callout, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(
                                Capsule().fill(
                                    LinearGradient(
                                        colors: [Color.jotBlueTop, Color.jotBlueBottom],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!embeddingsEnabled)
                    .opacity(embeddingsEnabled ? 1 : 0.4)
                }
            }
            .padding(.horizontal, JotDesign.Spacing.cardPaddingH)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(indexedChunkCount) \(indexedChunkCount == 1 ? "passage" : "passages") indexed.")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .padding(.horizontal, 4)
    }

    private var toggleSubline: String {
        if embeddingsEnabled {
            return "Each dictation is split into passages and embedded — the substrate for search and Ask."
        }
        return "Off. New dictations won't be indexed."
    }

    // MARK: - Actions

    private func startRebuild() {
        guard !isRebuilding else { return }
        isRebuilding = true
        rebuildDone = 0
        rebuildTotal = 0
        rebuildTask = Task {
            await TranscriptIndexer.rebuildAll { done, total in
                rebuildDone = done
                rebuildTotal = total
            }
            isRebuilding = false
            rebuildTask = nil
            refreshCounts()
        }
    }

    private func refreshCounts() {
        indexedChunkCount = ChunkStore.count(modelVersion: EmbeddingGemmaService.modelVersion)
    }
}
#endif
