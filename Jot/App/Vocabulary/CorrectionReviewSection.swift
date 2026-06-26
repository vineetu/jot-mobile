import SwiftUI

/// **Review Jot's Corrections — the summary-row + accordion** (the "review them
/// all here" surface). Per OCCURRENCE, shows every word the gate changed
/// (`CHANGED`) or kept (`KEPT`) and lets the owner adjudicate by **picking the
/// word they meant** (never yes/no). State + actions live in the shared
/// `CorrectionReviewModel` so this and the in-text tap bubble stay in sync.
///
/// Lives INSIDE the transcript scroll content, below the body text. Renders
/// nothing when the transcript has no proposals.
struct CorrectionReviewSection: View {
    @Bindable var model: CorrectionReviewModel

    /// review-ui.jsx CAP=4: >5 rows → show first 4 + "Show N more".
    private static let cap = 4
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: JotDesign.Spacing.cardGap + 2) {  // ~14pt gap
            if !model.records.isEmpty {
                summaryCard
                if model.accordionExpanded {
                    reviewCard
                }
            }
        }
        .padding(.horizontal, JotDesign.Spacing.pageGutter)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .animation(.timingCurve(0.45, 0.02, 0.2, 1, duration: 0.3), value: model.accordionExpanded)
        .task(id: model.transcript.id) { await model.reload() }
    }

    // MARK: - Cards

    /// `--card` surface: white@78% light / white@6% dark, 0.5px hairline, radius 22.
    private func cardSurface() -> some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(Self.cardFill)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.jotPageSeparator, lineWidth: 0.5))
    }

    /// `--card`: light = white@78%, dark = white@6%.
    private static let cardFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 1.0, alpha: 0.06)
            : UIColor(white: 1.0, alpha: 0.78)
    })

    private var summaryCard: some View {
        summaryRow.background(cardSurface())
    }

    private var reviewCard: some View {
        let rows = model.records
        let visible = (showAll || rows.count <= Self.cap + 1)
            ? Array(rows.enumerated())
            : Array(rows.enumerated().prefix(Self.cap))
        return VStack(alignment: .leading, spacing: 0) {
            reviewHeader
            ForEach(visible, id: \.element.key) { idx, r in
                row(r).padding(.vertical, 13)
                if idx != visible.count - 1 || visible.count < rows.count {
                    Divider().background(Color.jotPageSeparator)
                }
            }
            if visible.count < rows.count {
                Button {
                    withAnimation(.timingCurve(0.45, 0.02, 0.2, 1, duration: 0.3)) { showAll = true }
                } label: {
                    Text("Show \(rows.count - visible.count) more")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Color.jotAccent)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 6)
        .background(cardSurface())
    }

    /// Expanded review-list header (review-ui.jsx `rv-review-head`) — DISTINCT
    /// from the collapsed summary sub.
    /// Expanded-list hint. The count + "All reviewed" already live in the summary
    /// row above, so don't repeat them here — just a short, non-3rd-person nudge.
    @ViewBuilder
    private var reviewHeader: some View {
        if !model.allReviewed {
            Text("Tap the word you meant.")
                .font(.system(size: 13))
                .foregroundStyle(Color.jotPageInkSecondary)
                .padding(.bottom, 12)
        }
    }

    private var summaryRow: some View {
        Button { model.accordionExpanded.toggle() } label: {
            HStack(spacing: 10) {
                if model.allReviewed {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.jotAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.allReviewed
                        ? "All reviewed"
                        : "Jot guessed on \(model.records.count) word\(model.records.count == 1 ? "" : "s").")
                        .font(.system(size: 15.5, weight: .semibold)).tracking(-0.2)
                        .foregroundStyle(Color.jotPageInk)
                    if !model.allReviewed {
                        Text("Tap an underlined word — or review them all here.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Color.jotPageInkSecondary)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotPageInkCaption)
                    .rotationEffect(.degrees(model.accordionExpanded ? 90 : 0))
            }
            .padding(16).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ r: CorrectionProvenance.Record) -> some View {
        if let verdict = model.verdict(of: r) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark").font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.jotAccent).padding(.top, 1)
                CorrectionCopy.resolvedText(r, verdict: verdict)
                    .font(.system(size: 13.5)).lineSpacing(2)
                Spacer(minLength: 8)
                Button("Undo") { Task { await model.undo(r) } }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.jotAccent).buttonStyle(.plain)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                // Spoken context first — so when several rows share a word ("name"),
                // the owner can tell WHICH occurrence each row is about (the
                // keyboard nudge shows this; the accordion was missing it).
                if let ctx = model.context(for: r) {
                    contextLine(ctx)
                }
                CorrectionRowHeader(record: r)
                CorrectionChips(record: r) { choice in Task { await model.pick(r, choice: choice) } }
            }
        }
    }

    /// The spoken line for a row — SF Pro (like the keyboard), with the
    /// gated word emphasized + dash-underlined so it's findable in the snippet.
    private func contextLine(_ ctx: (before: String, gated: String, after: String)) -> some View {
        (Text(ctx.before).foregroundColor(Color.jotPageInkCaption)
            + Text(ctx.gated).foregroundColor(Color.jotPageInk)
                .underline(true, pattern: .dash, color: Color.jotPageInkCaption)
            + Text(ctx.after).foregroundColor(Color.jotPageInkCaption))
            .font(.system(size: 14, weight: .regular, design: .default))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The tap bubble anchored at a marked word (in-text primary surface). Same
/// pick-the-word chips as the accordion. On pick it shows the resolved
/// consequence line for 1.3s, then dismisses (handoff §word-bubble).
struct CorrectionBubble: View {
    let record: CorrectionProvenance.Record
    /// Arrow x within the bubble (word x relative to the bubble's left edge).
    var arrowX: CGFloat
    /// True when the bubble sits ABOVE the word (arrow on the bottom edge).
    var above: Bool
    /// Called with the picked side ("term"/"original") to run the verdict.
    var onPick: (String) -> Void
    /// Called after the 1.3s resolved dwell to dismiss the bubble.
    var onResolvedDismiss: () -> Void

    /// Once a side is picked we keep the bubble up showing the consequence line.
    @State private var pickedVerdict: String?

    private static let arrowSize: CGFloat = 12

    var body: some View {
        bubbleBody
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .frame(width: 272, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Self.bubbleFill)
                    // Closest to handoff `0 12px 30px -8px rgba(20,35,60,0.35)`.
                    // SwiftUI shadows have no negative spread, so radius/offset
                    // approximate it; the -8px inset is not expressible.
                    .shadow(color: Color(red: 20/255, green: 35/255, blue: 60/255).opacity(0.35),
                            radius: 30, x: 0, y: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.jotPageSeparator, lineWidth: 0.5))
            // Caret pointing at the word.
            .overlay(alignment: above ? .bottom : .top) {
                arrow
                    .offset(x: arrowOffsetX, y: above ? Self.arrowSize / 2 : -Self.arrowSize / 2)
            }
    }

    /// 12×12 rotated square caret pointing at the word. The fill matches the
    /// bubble so the two edges that overlap the bubble body disappear, leaving a
    /// triangular caret off the bubble's edge. (Per-edge hairline on only the two
    /// outward sides isn't cleanly expressible on a rotated square in SwiftUI —
    /// the full-perimeter hairline is an accepted approximation.)
    private var arrow: some View {
        Rectangle()
            .fill(Self.bubbleFill)
            .frame(width: Self.arrowSize, height: Self.arrowSize)
            .overlay(Rectangle().stroke(Color.jotPageSeparator, lineWidth: 0.5))
            .rotationEffect(.degrees(45))
    }

    /// Anchor the arrow at the word's x, clamped inside the bubble so it never
    /// pokes past a rounded corner.
    private var arrowOffsetX: CGFloat {
        let half: CGFloat = 272 / 2
        let clamped = min(max(arrowX, 18), 272 - 18)
        return clamped - half
    }

    @ViewBuilder
    private var bubbleBody: some View {
        if let v = pickedVerdict {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "checkmark").font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color.jotAccent).padding(.top, 1)
                // Bubble fill + ink tokens both follow the system color scheme
                // (white bubble/dark ink in light; navy bubble/light ink in dark),
                // so the adaptive tokens already read correctly here.
                CorrectionCopy.resolvedText(record, verdict: v)
                    .font(.system(size: 13.5)).lineSpacing(2)
                Spacer(minLength: 0)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                CorrectionRowHeader(record: record)
                CorrectionChips(record: record) { choice in
                    onPick(choice)
                    withAnimation(.easeOut(duration: 0.15)) { pickedVerdict = choice }
                    // Show the consequence line for 1.3s, then dismiss.
                    Task {
                        try? await Task.sleep(for: .milliseconds(1300))
                        onResolvedDismiss()
                    }
                }
            }
        }
    }

    /// dark = rgba(28,38,56,0.96); light = white.
    private static let bubbleFill = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(red: 28/255, green: 38/255, blue: 56/255, alpha: 0.96)
            : UIColor.white
    })
}

// MARK: - Shared atoms

/// Badge + "Jot wrote/heard …" note row.
struct CorrectionRowHeader: View {
    let record: CorrectionProvenance.Record
    var body: some View {
        let applied = (record.outcome == "applied")
        HStack(spacing: 8) {
            Text(applied ? "CHANGED" : "KEPT")
                .font(.system(size: 10, weight: .bold)).tracking(1.2)
                .foregroundStyle(applied ? Color.jotAccent : Color.jotPageInkSecondary)
                .padding(.horizontal, 8).padding(.vertical, 3.5)
                .background(
                    applied
                        ? AnyView(Capsule().fill(Color.jotAccent.opacity(0.20)))
                        // KEPT = chrome-fill style: subtle fill + 0.5px hairline border.
                        : AnyView(Capsule().fill(Color.jotPageInkCaption.opacity(0.10))
                            .overlay(Capsule().strokeBorder(Color.jotPageSeparator, lineWidth: 0.5))))
            // Plain label, not 3rd-person narration ("Jot wrote this for…") — the
            // badge already says CHANGED/KEPT; this just names the heard word.
            (Text("Original ").foregroundStyle(Color.jotPageInkCaption)
                + Text("\u{201C}\(record.originalWord)\u{201D}").foregroundStyle(Color.jotPageInkSecondary))
                .font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
    }
}

/// The two "pick the word you meant" chips (original first; in-text one tagged).
struct CorrectionChips: View {
    let record: CorrectionProvenance.Record
    var onPick: (String) -> Void
    var body: some View {
        let applied = (record.outcome == "applied")
        // A word must never wrap mid-word inside a chip ("Rochit / ha"). Try the
        // two chips side-by-side; if they don't fit the width, STACK them (each on
        // its own line) rather than break a long name.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chip(record.originalWord, inText: !applied) { onPick("original") }
                                 chip(record.term, inText: applied) { onPick("term") } }
            VStack(alignment: .leading, spacing: 8) { chip(record.originalWord, inText: !applied) { onPick("original") }
                                                      chip(record.term, inText: applied) { onPick("term") } }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func chip(_ word: String, inText: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(word).font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Color.jotPageInk)
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                if inText {
                    Text("IN TEXT").font(.system(size: 9, weight: .bold)).tracking(1)
                        .foregroundStyle(Color.jotPageInkCaption).fixedSize()
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Capsule().fill(Color.jotPageBase.opacity(0.6))
                .overlay(Capsule().strokeBorder(Color.jotPageSeparator, lineWidth: 0.5)))
        }
        .buttonStyle(.plain)
    }
}

enum CorrectionCopy {
    /// Resolved-row copy split into a BOLD lead segment + secondary-ink rest,
    /// matching `resolvedCopy()` (review-data.js) for the non-learning branches.
    /// (n>1 and graduated branches deferred — per-occurrence + no graduation copy.)
    static func resolvedParts(_ r: CorrectionProvenance.Record, verdict: String) -> (strong: String, rest: String) {
        let applied = (r.outcome == "applied")
        if verdict == "term" {
            return applied
                ? (r.term, " confirmed.")
                : (r.term, " applied here.")
        }
        return applied
            ? (r.originalWord, " restored.")
            : (r.originalWord, " kept.")
    }

    /// Concatenated `Text`: bold term lead in primary ink + rest in secondary ink.
    /// Both inks adapt to the system color scheme, so this reads correctly on the
    /// accordion card AND the (scheme-following) word bubble.
    static func resolvedText(_ r: CorrectionProvenance.Record, verdict: String) -> Text {
        let p = resolvedParts(r, verdict: verdict)
        return Text(p.strong).font(.system(size: 13.5, weight: .semibold)).foregroundColor(Color.jotPageInk)
            + Text(p.rest).foregroundColor(Color.jotPageInkSecondary)
    }
}
