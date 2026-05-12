//
//  JotDesignCatalog.swift
//  Jot
//
//  Phase 1 of the UX overhaul — design-system preview catalog.
//  See: Jot/tmp/ux-overhaul-plan.md §12 (Phase 1 deliverables).
//
//  Renders every color token, typography style, glass tier, icon-box size,
//  status-pill variant, the section label, and a fake row with a chevron so
//  Xcode previews give the visual reference for Phase 2+ integration.
//

import SwiftUI

#if DEBUG

struct JotDesignCatalog: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGap) {

                SectionLabel("Color tokens")
                colorSwatches

                SectionLabel("Typography")
                typographySamples

                SectionLabel("Glass surfaces")
                glassCardSamples

                SectionLabel("Icon boxes")
                iconBoxRow

                SectionLabel("Status pills")
                statusPillRow

                SectionLabel("Section label")
                SectionLabel("Speech model")

                SectionLabel("Row + chevron")
                fakeRow
            }
            .padding(JotDesign.Spacing.pageMargin)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            // Phase 1 punch-list FIX 9: hand-hex'd gradient hoisted to
            // `JotDesign.background` so any future page chrome shares it.
            JotDesign.background
                .ignoresSafeArea()
        )
    }

    // MARK: Color swatches

    private var colorSwatches: some View {
        let entries: [(String, Color)] = [
            ("jotAccent", .jotAccent),
            ("jotRecord", .jotRecord),
            ("jotInk", .jotInk),
            ("jotMute", .jotMute),
            ("jotMuteWeak", .jotMuteWeak),
            ("jotSuccess", .jotSuccess),
            ("jotSuccessInk", .jotSuccessInk),
            ("jotWarning", .jotWarning),
            ("jotWarningInk", .jotWarningInk)
        ]
        return VStack(spacing: 8) {
            ForEach(entries, id: \.0) { entry in
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(entry.1)
                        .frame(width: 44, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                        )
                    Text(entry.0)
                        .font(JotType.bodyChrome)
                        .foregroundStyle(Color.jotInk)
                    Spacer()
                }
            }
        }
    }

    // MARK: Typography samples

    private var typographySamples: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Editorial Display")
                .font(JotType.editorialDisplay)
                .foregroundStyle(Color.jotInk)
            Text("Editorial Title")
                .font(JotType.editorialTitle)
                .foregroundStyle(Color.jotInk)
            Text("Editorial Body")
                .font(JotType.editorialBody)
                .foregroundStyle(Color.jotInk)
            Text("Editorial Italic")
                .font(JotType.editorialItalic)
                .foregroundStyle(Color.jotInk)
            Text("Body chrome — system body for rows + buttons")
                .font(JotType.bodyChrome)
                .foregroundStyle(Color.jotInk)
            Text("Chrome Bold — primary actions")
                .font(JotType.chromeBold)
                .foregroundStyle(Color.jotInk)
            Text("CAPTION LABEL")
                .font(JotType.captionLabel)
                .tracking(JotDesign.Spacing.sectionLabelTracking)
                .foregroundStyle(Color.jotMute)
            Text("10:32  mono timestamp")
                .font(JotType.monoTimestamp)
                .foregroundStyle(Color.jotMute)
        }
    }

    // MARK: Glass cards (two tiers)

    private var glassCardSamples: some View {
        VStack(spacing: JotDesign.Spacing.cardGap) {
            GlassCard(tier: .regular) {
                HStack {
                    Text("Regular glass card")
                        .font(JotType.bodyChrome)
                        .foregroundStyle(Color.jotInk)
                    Spacer()
                    RowChevron()
                }
            }
            GlassCard(tier: .heavy) {
                HStack {
                    Text("Heavy glass — action bars + sheets")
                        .font(JotType.chromeBold)
                        .foregroundStyle(Color.jotInk)
                    Spacer()
                    RowChevron()
                }
            }
            GlassCard(tier: .key, padding: 12) {
                HStack {
                    Text("Key chrome — hand-rolled gradient, sub-44pt")
                        .font(JotType.bodyChrome)
                        .foregroundStyle(Color.jotInk)
                    Spacer()
                }
            }
        }
    }

    // MARK: Icon boxes (36pt + 44pt, multiple tints)

    private var iconBoxRow: some View {
        HStack(spacing: 16) {
            IconBox(symbol: "waveform", tint: .jotAccent, size: 36)
            IconBox(symbol: "wand.and.stars", tint: .jotAccent, size: 44)
            IconBox(symbol: "book", tint: Color(red: 0.34, green: 0.70, blue: 0.78), size: 36)
            IconBox(symbol: "lock", tint: .jotSuccess, size: 36)
            IconBox(symbol: "mic.fill", tint: .jotRecord, size: 44)
            Spacer()
        }
    }

    // MARK: Status pills

    private var statusPillRow: some View {
        HStack(spacing: 8) {
            StatusPill(label: "Ready", tint: .success)
            StatusPill(label: "Downloading", tint: .info)
            StatusPill(label: "Update available", tint: .warning)
            Spacer()
        }
    }

    // MARK: Fake row with chevron

    private var fakeRow: some View {
        GlassCard(tier: .regular) {
            HStack(spacing: 12) {
                IconBox(symbol: "gearshape", tint: Color(red: 0.55, green: 0.55, blue: 0.58), size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Settings")
                        .font(JotType.bodyChrome)
                        .foregroundStyle(Color.jotInk)
                    Text("Speech model, vocabulary, AI rewrite")
                        .font(.caption)
                        .foregroundStyle(Color.jotMute)
                }
                Spacer()
                RowChevron()
            }
        }
    }
}

#Preview("Light") {
    JotDesignCatalog()
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    JotDesignCatalog()
        .preferredColorScheme(.dark)
}

#endif
