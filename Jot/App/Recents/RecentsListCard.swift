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
    @Binding var isSelectionMode: Bool
    @Binding var selectedTranscriptIDs: Set<UUID>
    @Binding var navPath: NavigationPath
    let onCopy: (Transcript) -> Void
    let onDelete: (Transcript) -> Void
    let onEnterSelectionMode: (Transcript) -> Void

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
        // In selection mode, render the row WITHOUT the SwipeToRevealRow
        // wrapper. Even when SwipeToRevealRow's drag gesture is inert
        // (it guards on `!isSelectionMode`), the DragGesture(minimumDistance: 0)
        // is still ATTACHED, which claims touches at touch-down and blocks
        // the parent ScrollView's vertical pan. Skipping the wrapper entirely
        // in selection mode lets the user scroll while selecting.
        if isSelectionMode {
            selectableRow(
                for: transcript,
                isSelected: selectedTranscriptIDs.contains(transcript.id)
            )
            .contentShape(Rectangle())
            .onTapGesture {
                toggleSelection(for: transcript)
            }
            .accessibilityLabel(selectionAccessibilityLabel(for: transcript))
            .accessibilityHint("Toggles selection")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                toggleSelection(for: transcript)
            }
        } else {
            SwipeToRevealRow(
                isSelectionMode: $isSelectionMode,
                onDelete: { onDelete(transcript) }
            ) {
                // Plain content, NO NavigationLink / Button wrapper. Tap navigates
                // via programmatic NavigationPath append; long-press enters select
                // mode; horizontal drag (handled by SwipeToRevealRow's gesture)
                // reveals delete. With no internal Button intercepting touches,
                // SwiftUI's natural tap-slop + long-press semantics keep gestures
                // from firing each other: tap with movement = no tap, long hold
                // with no movement = long-press, brief tap = navigate.
                rowContent(for: transcript)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navPath.append(transcript.id)
                    }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        onEnterSelectionMode(transcript)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction {
                        navPath.append(transcript.id)
                    }
                    .accessibilityAction(named: Text("Enter selection mode")) {
                        onEnterSelectionMode(transcript)
                    }
            }
        }
    }

    @ViewBuilder
    private func rowContent(for transcript: Transcript) -> some View {
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

    private func selectableRow(for transcript: Transcript, isSelected: Bool) -> some View {
        HStack(alignment: .center, spacing: 0) {
            RecentsSelectionCheckbox(isSelected: isSelected)
                .padding(.leading, 8)

            rowContent(for: transcript)
        }
        .contentShape(Rectangle())
    }

    private func toggleSelection(for transcript: Transcript) {
        if selectedTranscriptIDs.contains(transcript.id) {
            selectedTranscriptIDs.remove(transcript.id)
        } else {
            selectedTranscriptIDs.insert(transcript.id)
        }
    }

    private func selectionAccessibilityLabel(for transcript: Transcript) -> String {
        let state = selectedTranscriptIDs.contains(transcript.id) ? "Selected" : "Not selected"
        return "\(state), \(transcript.displayText)"
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

private struct RecentsSelectionCheckbox: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.jotBlueTop : Color.clear)
                .overlay {
                    Circle()
                        .strokeBorder(
                            isSelected ? Color.jotBlueTop : Color.jotPageInkSecondary.opacity(0.45),
                            lineWidth: 0.75
                        )
                }
                .frame(width: 22, height: 22)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white)
            }
        }
        .frame(width: 44, height: 44)
        .contentShape(Circle())
        .accessibilityLabel(isSelected ? "Selected" : "Not selected")
    }
}
