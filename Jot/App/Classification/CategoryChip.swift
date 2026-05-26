import SwiftUI
import SwiftData

/// Small chip that displays a `Transcript`'s current category and lets
/// the user override it via a tap-to-menu picker.
///
/// Used by:
/// - `TranscriptDetailView` subline (inline override from the Detail).
/// - `ClassificationsDashboardView` rows (override from the dashboard).
///
/// User overrides are persisted by writing `transcript.category = ...`
/// and saving the model context. Since `TranscriptClassifierTask` only
/// processes rows where `category == nil`, any non-nil category — model
/// guess OR user override — is sticky: the classifier won't touch it
/// again. Clearing back to nil (`Unclassified`) requeues the row for the
/// next BG fire.
@available(iOS 26.0, *)
struct CategoryChip: View {
    let transcript: Transcript
    @Environment(\.modelContext) private var modelContext

    /// Compact display shape. `.detailSubline` is the small chip used in
    /// the Transcript Detail subline; `.dashboardRow` is the slightly
    /// larger pill used in the Lab dashboard list rows.
    enum Shape {
        case detailSubline
        case dashboardRow
    }
    var shape: Shape = .detailSubline

    /// Optional "let the model classify this row" callback. When
    /// non-nil AND the transcript is currently unclassified, the menu
    /// shows a "✦ Classify automatically" entry at the top. The
    /// dashboard passes this closure for unclassified rows when Qwen
    /// weights are on disk and no other classify run is in flight; in
    /// any other context (Detail subline today, or any condition that
    /// would race a bulk run) the closure is nil and the entry is
    /// hidden.
    var onAutoClassify: (() -> Void)?

    var body: some View {
        Menu {
            // "Classify automatically" appears ONLY when the chip's
            // host has wired up an action AND the row is untagged.
            // Without both conditions there's nothing meaningful to
            // run — a row with an existing category doesn't need the
            // model to guess, and a chip with no callback (e.g. the
            // Detail subline) doesn't own the safeguard machinery.
            if let onAutoClassify, (transcript.category ?? "").isEmpty {
                Button {
                    onAutoClassify()
                } label: {
                    Label("Classify automatically", systemImage: "sparkles")
                }
                Divider()
            }

            ForEach(TranscriptClassifier.Category.allCases, id: \.self) { cat in
                Button {
                    setCategory(cat.rawValue)
                } label: {
                    Label(displayName(for: cat.rawValue), systemImage: symbol(for: cat.rawValue))
                }
            }
            Divider()
            Button(role: .destructive) {
                setCategory(nil)
            } label: {
                Label("Unclassified", systemImage: "questionmark.circle")
            }
        } label: {
            chipLabel
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Category: \(displayName(for: transcript.category))")
        .accessibilityHint("Tap to change category")
    }

    // MARK: - Label

    private var chipLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol(for: transcript.category))
                .font(.system(size: chipFontSize - 1, weight: .semibold))
            Text(displayName(for: transcript.category))
                .font(.system(size: chipFontSize, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint(for: transcript.category))
        .padding(.horizontal, chipHPadding)
        .padding(.vertical, chipVPadding)
        .background(
            Capsule(style: .continuous)
                .fill(tint(for: transcript.category).opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(tint(for: transcript.category).opacity(0.22), lineWidth: 0.5)
        )
        .contentShape(Capsule(style: .continuous))
    }

    private var chipFontSize: CGFloat {
        switch shape {
        case .detailSubline: return 11
        case .dashboardRow:  return 13
        }
    }

    private var chipHPadding: CGFloat {
        switch shape {
        case .detailSubline: return 7
        case .dashboardRow:  return 10
        }
    }

    private var chipVPadding: CGFloat {
        switch shape {
        case .detailSubline: return 2
        case .dashboardRow:  return 4
        }
    }

    // MARK: - Mutation

    /// Writes `transcript.category = newValue` and saves. Failures roll
    /// back the in-memory mutation so the chip re-renders the prior state.
    private func setCategory(_ newValue: String?) {
        let previous = transcript.category
        transcript.category = newValue
        do {
            try modelContext.save()
        } catch {
            transcript.category = previous
            modelContext.rollback()
        }
    }

    // MARK: - Display helpers

    /// Maps a category raw value (or `nil`) to its display label.
    private func displayName(for raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Unclassified" }
        switch raw.lowercased() {
        case "email":   return "Email"
        case "message": return "Message"
        case "note":    return "Note"
        case "code":    return "Code"
        case "general": return "General"
        default:        return raw.capitalized
        }
    }

    /// SF Symbol for each category. Outline icons (not `.fill`) so the
    /// chip reads as a label, not a primary action.
    private func symbol(for raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "questionmark.circle" }
        switch raw.lowercased() {
        case "email":   return "envelope"
        case "message": return "bubble.left"
        case "note":    return "note.text"
        case "code":    return "chevron.left.forwardslash.chevron.right"
        case "general": return "doc.text"
        default:        return "tag"
        }
    }

    /// Tint per category — kept distinct so the dashboard reads at a
    /// glance. Muted to avoid competing with primary UI elements when
    /// the chip appears in the Detail subline.
    private func tint(for raw: String?) -> Color {
        guard let raw, !raw.isEmpty else { return Color.jotMute }
        switch raw.lowercased() {
        case "email":   return Color(red: 0.10, green: 0.45, blue: 0.85)
        case "message": return Color(red: 0.13, green: 0.65, blue: 0.45)
        case "note":    return Color(red: 0.80, green: 0.55, blue: 0.10)
        case "code":    return Color(red: 0.55, green: 0.35, blue: 0.75)
        case "general": return Color(red: 0.40, green: 0.40, blue: 0.45)
        default:        return Color.jotMute
        }
    }
}
