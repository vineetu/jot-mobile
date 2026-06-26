//
//  SeeForYourselfPage.swift
//  Jot
//
//  Help → "See for yourself." — pushed from the Privacy row. Teaches the user
//  to verify Jot's on-device claim with iOS's App Privacy Report.
//
//  The report preview is STATIC copy — there is no public API to read the real
//  App Privacy Report, and no public deep-link into it. The "Open Settings" CTA
//  opens the iOS Settings root; the footnote shows the manual path.
//
//  Pushed on the ambient NavigationStack like the Feedback link. No internal
//  stack.
//

import SwiftUI

struct SeeForYourselfPage: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            WizardWallpaper()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    lead
                    reportSection
                    cta
                    footnote
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("See for yourself.")
                .font(.custom(JotType.frauncesSemiBold, size: 32))
                .foregroundStyle(Color.jotInk)
                .accessibilityAddTraits(.isHeader)

            Text("iOS keeps the receipts")
                .font(.custom(JotType.frauncesItalicText, size: 16))
                .foregroundStyle(Color.jotMute)
        }
        .padding(.top, 4)
    }

    /// Lead paragraph, bold lead-in then body. Composed inline so "No accounts,
    /// no cloud, no telemetry." renders bold without an AttributedString detour.
    private var lead: some View {
        (
            Text("No accounts, no cloud, no telemetry.")
                .font(.system(size: 15.5, weight: .semibold))
                .foregroundColor(Color.jotInk)
            + Text(" Your words never leave this iPhone — and you don't have to trust us on that. iOS logs every domain every app contacts, and Jot's list is short.")
                .font(.system(size: 15.5))
                .foregroundColor(Color.jotPageInkSecondary)
        )
        .lineSpacing(3)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("What Jot's report shows")
                .padding(.horizontal, 4)

            PrivacyReportPreview()

            Text("Anything from apple.com is iOS itself — the App Store handles donation receipts. That's the whole list.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.jotMute)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }

    private var cta: some View {
        Button {
            if let url = URL(string: UIApplication.openSettingsURLString) {
                openURL(url)
            }
        } label: {
            Text("Open Settings")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(
                    LinearGradient(
                        colors: [Color.jotBlueTop, Color.jotBlueBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: Capsule(style: .continuous)
                )
                .shadow(color: Color.jotAccent.opacity(0.44), radius: 15, x: 0, y: 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Settings")
        .accessibilityHint("Opens the iOS Settings app")
    }

    private var footnote: some View {
        Text("iOS can't jump straight to the report — from Settings, it's Privacy & Security › App Privacy Report.")
            .font(.system(size: 12.5))
            .foregroundStyle(Color.jotMute)
            .multilineTextAlignment(.center)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
    }
}

/// Static preview of the App Privacy Report — two domain rows with an activity
/// bar + contact count + caption. NOT a live read (no API); the numbers are
/// fixed copy that mirror Jot's actual short list.
struct PrivacyReportPreview: View {
    var body: some View {
        GlassCard(tier: .regular, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                domainRow(
                    domain: "huggingface.co",
                    barWidth: 72,
                    count: "4",
                    caption: "Speech & rewrite models — only when you ask to download one"
                )

                HelpRowDivider(inset: 0)

                domainRow(
                    domain: "jot-donations.ideaflow.page",
                    barWidth: 24,
                    count: "1",
                    caption: "Donations page & feedback you choose to send"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func domainRow(domain: String, barWidth: CGFloat, count: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(domain)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(Color.jotInk)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.jotAccent)
                    .frame(width: barWidth, height: 4)

                Text(count)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.jotMute)
            }

            Text(caption)
                .font(.system(size: 13))
                .foregroundStyle(Color.jotMute)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(domain), \(count) contacts. \(caption)")
    }
}

#Preview {
    NavigationStack {
        SeeForYourselfPage()
    }
}
