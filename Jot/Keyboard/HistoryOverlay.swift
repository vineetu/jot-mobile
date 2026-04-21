import SwiftUI

/// Modal overlay listing recent Jot transcripts. Presented above the full
/// keyboard when the user taps the history glyph in ``KeyboardAccessoryBar``.
/// Tap a row → insert its text at the cursor and dismiss.
///
/// Lives in the keyboard extension only — reads the App Group JSON mirror
/// produced by the main app via ``TranscriptHistoryMirror``. Never touches
/// SwiftData directly (see that type's doc for why).
struct HistoryOverlay: View {
    let entries: [TranscriptHistoryMirror.Entry]
    let onInsert: (TranscriptHistoryMirror.Entry) -> Void
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header
            separator
            if entries.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Inherit the system keyboard plane background so there's no seam
        // between the overlay and the underlying keyboard surface.
        .background(.ultraThinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.secondary)
            Text("Jot history")
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: .label))
                    .frame(width: 32, height: 32)
                    .background(Color(uiColor: .keyboardDarkButtonBackground), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close history")
            .accessibilityAddTraits(.isButton)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Inherit the system keyboard plane background so there's no seam
        // between the overlay and the underlying keyboard surface.
        .background(.ultraThinMaterial)
    }

    // MARK: - Empty / list

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "text.bubble")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("No dictations yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Open Jot and record something — it'll show up here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    row(for: entry)
                    separator
                        .padding(.leading, 12)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Inherit the system keyboard plane background so there's no seam
        // between the overlay and the underlying keyboard surface.
        .background(.ultraThinMaterial)
    }

    // MARK: - Row

    private func row(for entry: TranscriptHistoryMirror.Entry) -> some View {
        Button {
            onInsert(entry)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(ledgerChip(for: entry.ledgerIndex))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Color(uiColor: .keyboardDarkButtonBackground)
                                .opacity(scheme == .dark ? 0.85 : 0.55),
                            in: RoundedRectangle(cornerRadius: 4)
                        )
                    Text(Self.relativeFormatter.localizedString(for: entry.createdAt, relativeTo: Date()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.down.backward.circle")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                Text(entry.text)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Transcript \(entry.ledgerIndex)")
        .accessibilityValue(entry.text)
        .accessibilityHint("Inserts this transcript at the cursor")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Helpers

    /// `#0041`-style chip matching the main-app ledger row. Zero-padded to
    /// four digits so the layout stays steady as the counter grows.
    private func ledgerChip(for index: Int) -> String {
        String(format: "#%04d", index)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    private var separator: some View {
        Rectangle()
            .fill(Color.black.opacity(scheme == .dark ? 0.35 : 0.12))
            .frame(height: 0.5)
    }
}
