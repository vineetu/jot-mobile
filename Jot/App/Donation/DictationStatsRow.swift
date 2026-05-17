import SwiftUI

/// Compact two-line usage readout shown at the top of Settings → About.
///
/// Reads from `DictationStats`, which sits in the App Group so the keyboard
/// extension's dictations count toward the same totals as in-app dictations.
/// The "saved over typing" figure applies the 2× multiplier from
/// `DictationStats.timeSavedMultiplier` — intentionally conservative so the
/// claim is defensible rather than impressive.
///
/// Why a separate row rather than another list item inside `GlassCard`:
/// the cumulative stat is a self-summary, not an action, and putting it
/// in the list would blur "this is a number about you" with "this is a
/// thing to tap." Promoting it to a standalone block above the list keeps
/// the visual hierarchy honest.
struct DictationStatsRow: View {
    var body: some View {
        let count = DictationStats.totalCount
        let savedSeconds = DictationStats.estimatedTimeSavedSeconds

        VStack(alignment: .leading, spacing: 4) {
            Text("\(count) \(count == 1 ? "dictation" : "dictations")")
                .font(.system(.callout, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Text("About \(Self.formatDuration(savedSeconds)) saved over typing.")
                .font(.system(.footnote))
                .foregroundStyle(Color.jotMute)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.jotInk.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.jotInk.opacity(0.08), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) dictations completed. About \(Self.formatDurationVerbose(savedSeconds)) saved over typing.")
    }

    /// Human-friendly compact format. Examples: "12m", "3h 5m", "47h".
    /// Drops the minutes component once we're past 20 hours — at that scale
    /// the minutes are noise.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return "\(minutes)m"
        }
        if hours >= 20 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }

    /// Verbose VoiceOver-friendly format. Reads naturally as a sentence
    /// rather than "3h 5m" (which screen readers fumble).
    private static func formatDurationVerbose(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(seconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        switch (hours, minutes) {
        case (0, let m): return "\(m) minute\(m == 1 ? "" : "s")"
        case (let h, 0): return "\(h) hour\(h == 1 ? "" : "s")"
        case (let h, let m):
            return "\(h) hour\(h == 1 ? "" : "s") and \(m) minute\(m == 1 ? "" : "s")"
        }
    }
}

#Preview {
    DictationStatsRow()
        .padding()
        .background(JotDesign.background)
}
