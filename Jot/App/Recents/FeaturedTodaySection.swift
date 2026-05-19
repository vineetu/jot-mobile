import SwiftUI

/// Visually-unified 'featured section' for the top of the Recents list.
/// Renders the section label (e.g. TODAY) and the featured LATEST row
/// inside ONE soft blue gradient panel, so the section header is structurally
/// part of the featured chrome rather than floating on the parent glass card.
/// Also renders any trailing non-featured rows that share the same group
/// (e.g. additional TODAY entries below LATEST), with dividers, so the
/// gradient closes cleanly at the group boundary.
struct FeaturedTodaySection: View {
    let title: String
    let items: [Transcript]
    let copiedTranscriptID: UUID?
    let rowBuilder: (Transcript) -> AnyView

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Section label inside the gradient panel (TODAY). Styling
            // mirrors RecentsListCard.groupLabel for the first group.
            Text(title.uppercased())
                .font(JotType.sectionLabel)
                .tracking(1.5)
                .foregroundStyle(Color.jotPageInkCaption)
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)

            // Rows for the group. The first item gets the FeaturedLatestRow
            // treatment via rowBuilder (which RecentsListCard wires up with
            // navigation, context menu, selection, and swipe-reveal actions); siblings
            // render as standard rows.
            ForEach(Array(items.enumerated()), id: \.element.id) { itemIndex, transcript in
                rowBuilder(transcript)

                if itemIndex != items.count - 1 {
                    Divider()
                        .overlay(Color.jotPageSeparator)
                        .padding(.leading, 18)
                }
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color.jotBlueTop.opacity(0.10),
                    Color.jotBlueTop.opacity(0.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}
