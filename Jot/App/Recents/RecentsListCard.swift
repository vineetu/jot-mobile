import SwiftUI

struct RecentsTranscriptGroup: Identifiable {
    let title: String
    let items: [Transcript]

    var id: String { title }
}

struct RecentsListCard: View {
    let transcripts: [Transcript]
    let groups: [RecentsTranscriptGroup]
    let isSearching: Bool
    let copiedTranscriptID: UUID?
    /// When true, render a live streaming row at the top of the card and
    /// suppress the featured "LATEST" treatment on the most recent transcript
    /// — the live row IS the user's current "latest" while the mic is hot.
    let isLiveRecording: Bool
    /// Live partial transcript text forwarded from the streaming presenter.
    /// Empty string until the first partial arrives.
    let liveStreamingText: String
    let onCopy: (Transcript) -> Void
    let onDelete: (Transcript) -> Void

    private var featuredID: UUID? {
        groups.first?.items.first?.id
    }

    var body: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            Group {
                if transcripts.isEmpty && !isLiveRecording {
                    emptyState
                } else if isSearching && groups.isEmpty && !isLiveRecording {
                    noMatchesState
                } else {
                    groupedRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var groupedRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLiveRecording {
                LiveStreamingRow(streamingText: liveStreamingText)

                if !groups.isEmpty {
                    Divider()
                        .overlay(Color.jotPageSeparator)
                        .padding(.leading, 18)
                }
            }

            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                if groupIndex == 0 && group.items.first?.id == featuredID && !isLiveRecording {
                    FeaturedTodaySection(
                        title: group.title,
                        items: group.items,
                        copiedTranscriptID: copiedTranscriptID,
                        rowBuilder: { transcript in AnyView(self.row(for: transcript)) }
                    )
                } else {
                    groupLabel(group.title, isFirst: groupIndex == 0)
                    rows(for: group)
                }

                if groupIndex != groups.count - 1 {
                    Divider()
                        .overlay(Color.jotPageSeparator)
                        .padding(.leading, 18)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isLiveRecording)
    }

    private func groupLabel(_ title: String, isFirst: Bool) -> some View {
        Text(title.uppercased())
            .font(JotType.sectionLabel)
            .tracking(1.5)
            .foregroundStyle(Color.jotPageInkCaption)
            .padding(.horizontal, 18)
            .padding(.top, isFirst ? 14 : 16)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func rows(for group: RecentsTranscriptGroup) -> some View {
        ForEach(Array(group.items.enumerated()), id: \.element.id) { itemIndex, transcript in
            row(for: transcript)

            if itemIndex != group.items.count - 1 {
                Divider()
                    .overlay(Color.jotPageSeparator)
                    .padding(.leading, 18)
            }
        }
    }

    @ViewBuilder
    private func row(for transcript: Transcript) -> some View {
        NavigationLink {
            TranscriptDetailView(
                transcript: transcript,
                keyboardRewriteIntent: nil
            )
        } label: {
            if transcript.id == featuredID && !isLiveRecording {
                FeaturedLatestRow(
                    transcript: transcript,
                    isCopied: copiedTranscriptID == transcript.id
                )
            } else {
                AliveRow(
                    transcript: transcript,
                    isCopied: copiedTranscriptID == transcript.id
                )
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                onCopy(transcript)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Button(role: .destructive) {
                onDelete(transcript)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                onDelete(transcript)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.jotPageInkSecondary)

            Text("No transcripts yet")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)

            Text("Tap Dictate to record your first note.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotPageInkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 60)
        .accessibilityElement(children: .combine)
    }

    private var noMatchesState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Color.jotPageInkSecondary)

            Text("No matches")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotPageInk)

            Text("Try a different search.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotPageInkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 60)
        .accessibilityElement(children: .combine)
    }
}
