import SwiftUI

/// Suggestions from the system grammar checker for the transcript being
/// edited (features.md §3.7). One row per issue: the flagged words, the
/// checker's note, and the replacement(s) it proposes. Nothing is applied
/// until the user taps a replacement — dictated names and vocabulary terms
/// are exactly what a grammar checker likes to "fix", so every change is the
/// user's call. Ignore drops the row for this session.
struct ProofreadSheet: View {
    let issues: [GrammarIssue]
    let onApply: (GrammarIssue, String) -> Void
    let onIgnore: (GrammarIssue) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                WallpaperBackground().ignoresSafeArea()
                if issues.isEmpty {
                    allClear
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(headline)
                                .font(JotType.rowSub)
                                .foregroundStyle(Color.jotPageInkSecondary)
                                .padding(.horizontal, 4)
                            ForEach(issues) { issue in
                                issueCard(issue)
                            }
                            Text("Checked on your iPhone by the system grammar checker. Names and your vocabulary terms can be flagged by mistake — ignore what's right.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.jotPageInkCaption)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 4)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, JotDesign.Spacing.pageGutter)
                        .padding(.top, 12)
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Proofread")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var headline: String {
        let n = issues.count
        return "\(n) \(n == 1 ? "suggestion" : "suggestions")"
    }

    private var allClear: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.jotSuccess)
            Text("Looks good")
                .font(JotType.rowTitle)
                .foregroundStyle(Color.jotPageInk)
            Text("No spelling or grammar suggestions.")
                .font(JotType.rowSub)
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func issueCard(_ issue: GrammarIssue) -> some View {
        LiquidGlassCard(paddingH: 16, paddingV: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(issue.kind == .spelling ? "SPELLING" : "GRAMMAR")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(Color.orange)
                    Text("\u{201C}\(issue.original)\u{201D}")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.jotPageInk)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }

                if !issue.detail.isEmpty {
                    Text(issue.detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    if issue.hasSuggestion {
                        ForEach(issue.suggestions.prefix(3), id: \.self) { suggestion in
                            Button {
                                onApply(issue, suggestion)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 11, weight: .bold))
                                    Text(suggestion.isEmpty ? "Remove" : suggestion)
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 34)
                                .background(Capsule(style: .continuous).fill(Color.jotBlueTop))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Replace with \(suggestion)")
                        }
                    } else {
                        Text("No automatic fix — edit it yourself.")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.jotPageInkCaption)
                    }
                    Spacer(minLength: 0)
                    Button("Ignore") { onIgnore(issue) }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .buttonStyle(.plain)
                        .frame(minHeight: 34)
                        .accessibilityLabel("Ignore this suggestion")
                }
            }
        }
    }
}

#Preview {
    ProofreadSheet(
        issues: [
            GrammarIssue(id: UUID(), kind: .spelling, range: NSRange(location: 0, length: 5),
                         original: "recieve", detail: "", suggestions: ["receive"]),
            GrammarIssue(id: UUID(), kind: .grammar, range: NSRange(location: 10, length: 8),
                         original: "was went", detail: "Verb form may be incorrect.", suggestions: ["went", "was going"]),
        ],
        onApply: { _, _ in },
        onIgnore: { _ in }
    )
}
