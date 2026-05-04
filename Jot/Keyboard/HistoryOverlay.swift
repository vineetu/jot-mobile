import SwiftUI

struct HistoryOverlay: View {
    let entries: [TranscriptHistoryMirror.Entry]
    let onInsert: (TranscriptHistoryMirror.Entry) -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if entries.isEmpty {
                emptyState
            } else {
                rows
            }
        }
        .frame(maxWidth: .infinity, maxHeight: 280, alignment: .top)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(uiColor: .separator).opacity(0.55), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            Text("Recent transcripts")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(uiColor: .label))
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .frame(width: 28, height: 28)
                    .background(Color(uiColor: .tertiarySystemFill), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close history")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Image(systemName: "text.bubble")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
            Text("No recent transcripts")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16)
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(entries) { entry in
                    row(for: entry)
                    if entry.id != entries.last?.id {
                        Divider()
                            .padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func row(for entry: TranscriptHistoryMirror.Entry) -> some View {
        Button {
            onInsert(entry)
        } label: {
            HStack(spacing: 10) {
                Text(entry.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                    .lineLimit(1)
                    .frame(width: 58, alignment: .leading)

                Text(entry.text)
                    .font(.footnote)
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.createdAt.formatted(date: .omitted, time: .shortened))
        .accessibilityValue(entry.text)
        .accessibilityHint("Inserts this transcript")
    }
}
