//
//  SectionLabel.swift
//  Jot
//
//  Phase 1 of the UX overhaul — design-system foundation.
//  See: Jot/tmp/ux-overhaul-plan.md §3.
//

import SwiftUI

/// UPPERCASE section heading — 11pt bold, 0.6pt tracking, `.jotMute` ink.
/// Use above settings sections, transcript lists, and any other grouped
/// surface that needs a textual heading.
///
/// The label always uppercases its input; pass `"speech model"` and it
/// renders as `SPEECH MODEL`.
///
/// Phase 1 punch-list FIX 6: typography pulled from `JotType.captionLabel`
/// instead of a hard-coded `Font.system(size: 11, weight: .bold)` so the
/// section-label face has a single source of truth.
struct SectionLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(JotType.captionLabel)
            .tracking(JotDesign.Spacing.sectionLabelTracking)
            .foregroundStyle(Color.jotMute)
            .accessibilityAddTraits(.isHeader)
    }
}
