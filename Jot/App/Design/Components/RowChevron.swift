//
//  RowChevron.swift
//  Jot
//
//  Phase 1 of the UX overhaul — design-system foundation.
//  See: Jot/tmp/ux-overhaul-plan.md §3.
//

import SwiftUI

/// 8pt × 14pt SF Symbols chevron tinted `.jotMuteWeak`. Use at the right edge
/// of every navigable settings row.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 8, height: 14)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.jotMuteWeak)
            .accessibilityHidden(true)
    }
}
