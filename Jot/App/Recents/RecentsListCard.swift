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
                if transcripts.isEmpty {
                    emptyState
                } else if isSearching && groups.isEmpty {
                    noMatchesState
                } else {
                    groupedRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var groupedRows: some View {
        // LazyVStack (not VStack): the rows live inside Recents' ScrollView, so
        // a plain VStack builds ALL transcript rows up front (eager). LazyVStack
        // only realizes the visible rows + a small buffer and recycles as you
        // scroll — the win that keeps a 500+ transcript home screen smooth.
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { groupIndex, group in
                if groupIndex == 0 && group.items.first?.id == featuredID {
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
        // wrapper — the swipe affordance is meaningless once the user is already
        // in selection mode, and skipping the wrapper keeps the parent
        // ScrollView's vertical pan unobstructed while selecting.
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
            // WS-E §1.11 — swipe-to-reveal (Select + Delete) that COEXISTS with
            // vertical scroll and tap-to-open. The mechanism is a per-row
            // horizontal `ScrollView` (`SwipeRevealRow`), NOT a hand-rolled
            // `DragGesture`: the prior gesture approach competed with the parent
            // ScrollView's UIKit pan and killed vertical scrolling (removed twice
            // in `2d6b7ae`). Nested orthogonal scroll views are arbitrated by
            // UIKit natively — vertical pan → the outer Recents scroll, horizontal
            // pan → this row's reveal — the same way App Store carousels live
            // inside a vertical feed. Tap still opens; long-press still selects.
            SwipeRevealRow(
                onDelete: { onDelete(transcript) },
                onSelect: { onEnterSelectionMode(transcript) }
            ) {
                rowContent(for: transcript)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        navPath.append(transcript.id)
                    }
                    .onLongPressGesture(minimumDuration: 0.5) {
                        onEnterSelectionMode(transcript)
                    }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                navPath.append(transcript.id)
            }
            .accessibilityAction(named: Text("Enter selection mode")) {
                onEnterSelectionMode(transcript)
            }
            .accessibilityAction(named: Text("Delete")) {
                onDelete(transcript)
            }
        }
    }

    @ViewBuilder
    private func rowContent(for transcript: Transcript) -> some View {
        if transcript.id == featuredID {
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

            Text("Tap Jot down to record your first note.")
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

/// WS-E §1.11 — swipe-to-reveal (Select + Delete) built on a per-row HORIZONTAL
/// `ScrollView`, not a hand-rolled `DragGesture`.
///
/// ## Why a nested ScrollView instead of a gesture
///
/// A custom `DragGesture` on a row inside the vertical Recents scroll cannot be
/// made to coexist with vertical scrolling: SwiftUI's gesture (even via
/// `simultaneousGesture` + a horizontal-bias check) does not compose with the
/// ScrollView's UIKit pan recognizer, so the drag wins the touch and kills the
/// vertical pan. This was removed twice already (see `2d6b7ae`).
///
/// Nesting a horizontal `ScrollView` inside the vertical one hands the
/// swipe-vs-scroll decision to UIKit's native scroll arbitration — the exact
/// mechanism App Store carousels use inside a vertical feed. A predominantly
/// vertical pan drives the outer Recents scroll; a predominantly horizontal pan
/// drives this row's reveal. Tap-to-open and long-press-to-select pass straight
/// through (a ScrollView intercepts pans, never taps).
///
/// Layout: `[ rowContent (full row width) | action tray (trayWidth) ]`. At rest
/// the tray sits just past the right edge, off-screen. A custom
/// `ScrollTargetBehavior` snaps the resting offset to either 0 (closed) or
/// `trayWidth` (open), so the row can't halt half-revealed.
private struct SwipeRevealRow<Content: View>: View {
    let onDelete: () -> Void
    let onSelect: () -> Void
    @ViewBuilder let content: Content

    /// Diameter of each circular action button (iOS Messages-style). Reduced
    /// 15% (46 → 39) per user request.
    private let circleDiameter: CGFloat = 39
    /// Revealed action-tray width: two circles + inter-spacing + side padding
    /// (39 + 12 + 39 + 28 = 118). This is the horizontal scroll distance.
    private let trayWidth: CGFloat = 118

    /// Measured natural height of `content`, used to lock the horizontal
    /// ScrollView's height. A ScrollView is greedy on its cross axis; without an
    /// explicit height it would collapse (or balloon) inside the LazyVStack. The
    /// content's intrinsic height does not depend on this frame, so the
    /// measurement settles in one pass (no layout feedback loop). Seeded at the
    /// 2-line row height (AliveRow reserves 2 lines — see `lineLimit(2,
    /// reservesSpace: true)`) so rows DON'T visibly resize/pop on realization.
    @State private var rowHeight: CGFloat = 76

    /// Stable id on the row content so `ScrollViewReader` can snap the row CLOSED
    /// (offset 0) programmatically when an action fires. Without this, a
    /// swipe-Delete that the user then CANCELS in the confirm dialog leaves the
    /// row stuck open — the offset lives in UIKit scroll state the parent can't
    /// otherwise reset. `scrollTo` drives the offset directly; the custom snap
    /// behavior only governs where a USER drag lands, so the two don't fight.
    private let closedAnchor = "swipe-row-closed"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    content
                        // Full row width — the tray then parks just off the right
                        // edge at rest. `containerRelativeFrame` resolves to this
                        // (inner) horizontal ScrollView's viewport width.
                        .containerRelativeFrame(.horizontal)
                        .id(closedAnchor)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: SwipeRowHeightKey.self,
                                    value: geo.size.height
                                )
                            }
                        )

                    actionTray(proxy: proxy)
                        .frame(width: trayWidth)
                        .frame(maxHeight: .infinity)
                }
            }
            // Explicit height is REQUIRED: a ScrollView is greedy on its cross
            // axis and would collapse/balloon inside the LazyVStack without it.
            .frame(height: rowHeight)
            .scrollTargetBehavior(SwipeSnapBehavior(trayWidth: trayWidth))
            // No bounce when there's nothing to reveal past the tray.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .onPreferenceChange(SwipeRowHeightKey.self) { height in
                if height > 0 { rowHeight = height }
            }
        }
    }

    /// Snaps the row closed, THEN runs `action`. Closing first means a Delete
    /// that routes to a confirm dialog leaves the row shut behind the dialog
    /// whether the user confirms or cancels — no stuck-open row.
    private func runClosing(_ action: @escaping () -> Void, proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(closedAnchor, anchor: .leading)
        }
        action()
    }

    private func actionTray(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 12) {
            actionButton(
                systemImage: "checkmark",
                tint: Color.jotBlueTop,
                label: "Select",
                action: { runClosing(onSelect, proxy: proxy) }
            )
            actionButton(
                systemImage: "trash.fill",
                tint: Color.jotRecord,
                label: "Delete",
                action: { runClosing(onDelete, proxy: proxy) }
            )
        }
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }

    private func actionButton(
        systemImage: String,
        tint: Color,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(width: circleDiameter, height: circleDiameter)
                .background(Circle().fill(tint))
                .shadow(color: tint.opacity(0.3), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Carries each row's natural content height out of its hidden GeometryReader so
/// `SwipeRevealRow` can lock its horizontal ScrollView to that height.
private struct SwipeRowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Snaps the per-row horizontal ScrollView's resting offset to fully-closed (0)
/// or fully-open (`trayWidth`) — never a half-revealed state. The proposed
/// `target.rect` already includes flick momentum, so a quick flick past the
/// midpoint opens, and a small drag back closes.
private struct SwipeSnapBehavior: ScrollTargetBehavior {
    let trayWidth: CGFloat

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        target.rect.origin.x = target.rect.minX > trayWidth * 0.5 ? trayWidth : 0
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
