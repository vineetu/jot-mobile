//
//  HelpView.swift
//  Jot
//
//  Pre-TestFlight Help surface (App Store requirement).
//
//  Editorial chrome — warm-cream wallpaper (shared with the wizard), Fraunces
//  display headers, Liquid Glass cards stacked vertically. Presented two ways:
//    1. As a navigation push from Settings → ABOUT → "Help & Support".
//    2. As a modal sheet from the home header's "?" glass-circle button.
//
//  Both entry points render the same content. The view picks its dismiss
//  affordance based on whether it sees an enclosing nav stack — in modal
//  presentation we surface a Done pill that calls `dismiss()`; pushed from
//  Settings, the native nav back button handles dismissal.
//
//  Why warm-cream (not `JotDesign.background`):
//  Help is read-y editorial content. The wizard's `WizardWallpaper` reads
//  warmer than the home's grey gradient and pairs well with Fraunces serif
//  headings + glass cards. The keyboard's gray retheme is unrelated — it
//  lives only inside the keyboard extension's chrome.
//

import SwiftUI

/// Standalone help screen. Use `HelpView()` for nav-push from Settings;
/// `HelpView(isModal: true)` to show a Done pill in the top-right when
/// presented as a sheet from the home header.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// `true` when presented via `.sheet(...)`. Controls whether the editorial
    /// header surfaces a glass "Done" pill (sheet path) or relies on the nav
    /// stack's native back button (push path).
    var isModal: Bool = false

    var body: some View {
        ZStack {
            // Warm-cream wallpaper shared with the wizard. Help is a
            // read-y editorial surface, not a chrome surface, so the
            // warmer backdrop reads better than the home's grey gradient.
            WizardWallpaper()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    gettingStartedSection
                    aiRewriteSection
                    privacySection
                    troubleshootingSection
                    contactSection
                    footer
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, isModal ? 8 : 4)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Only hide the nav bar when we're the root of our own modal stack.
        // When pushed from Settings, we keep the system nav bar so the
        // back chevron stays visible.
        .toolbar(isModal ? .hidden : .visible, for: .navigationBar)
    }

    // MARK: - Hero

    private var hero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Help")
                    .font(.custom(JotType.frauncesSemiBold, size: 32))
                    .foregroundStyle(Color.jotInk)
                    .accessibilityAddTraits(.isHeader)

                Spacer()

                if isModal {
                    // Glass Done pill mirrors `SettingsView`'s pattern so the
                    // sheet-presented Help screen has a parallel dismiss
                    // affordance. Hidden on the nav-push path because the
                    // system back button is already present.
                    Button {
                        dismiss()
                    } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.jotInk)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 9)
                            .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 22))
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Done")
                    .accessibilityHint("Dismisses Help")
                }
            }

            Text("Everything you need to know about Jot")
                .font(.custom(JotType.frauncesItalicText, size: 16))
                .foregroundStyle(Color.jotMute)
        }
        .padding(.top, 4)
    }

    // MARK: - Getting started

    private var gettingStartedSection: some View {
        editorialSection(title: "Getting started") {
            VStack(alignment: .leading, spacing: 14) {
                bulletParagraph(
                    "Tap the coral ",
                    boldRun: "Dictate",
                    " button on the home screen to record a thought, anywhere — even when you're not in another app."
                )

                bulletParagraph(
                    "To use Jot in any app, install the Jot keyboard once. Then tap the ",
                    boldRun: "globe",
                    " icon on iOS's keyboard to switch to Jot."
                )

                bulletParagraph(
                    "When you're in another app, tap ",
                    boldRun: "Dictate",
                    " on the Jot keyboard. Jot opens, records, transcribes, and pastes back automatically."
                )
            }
        }
    }

    // MARK: - AI rewrite

    private var aiRewriteSection: some View {
        editorialSection(title: "AI rewrite (optional)") {
            VStack(alignment: .leading, spacing: 14) {
                bulletParagraph(
                    "Jot ships with a built-in AI rewriter. Tap the ",
                    boldRun: "wand",
                    " icon on any transcript or in the keyboard to clean up filler words, fix grammar, or reformat into bullet points."
                )

                bulletParagraph(
                    "Rewrites happen entirely on-device using a 2.4 GB model. Your text never leaves your iPhone."
                )

                bulletParagraph(
                    "Optional download — enable AI Rewrite in ",
                    boldRun: "Settings",
                    " to get the model."
                )
            }
        }
    }

    // MARK: - Privacy

    private var privacySection: some View {
        editorialSection(title: "Privacy") {
            VStack(alignment: .leading, spacing: 14) {
                bulletParagraph(
                    "All transcription happens on-device. Audio never leaves your iPhone."
                )

                bulletParagraph(
                    "Transcripts are stored locally on your device. Jot has no cloud sync, no analytics, no account."
                )

                bulletParagraph(
                    "Optional AI rewrites are also on-device (Phi-4 mini)."
                )
            }
        }
    }

    // MARK: - Troubleshooting

    /// Collapsible Q&A rows for the four common failure modes from QA. We
    /// hand-roll the disclosure chrome on top of `DisclosureGroup` so the
    /// row taps land inside a `GlassCard` instead of the system's plain
    /// list row, keeping it visually aligned with the rest of the page.
    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Troubleshooting")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 8) {
                VStack(spacing: 0) {
                    troubleshootingRow(
                        question: "Keyboard didn't paste",
                        answer: "Make sure Full Access is enabled. Settings → General → Keyboard → Keyboards → Jot → Allow Full Access.",
                        showDivider: true
                    )
                    troubleshootingRow(
                        question: "Recording cut off",
                        answer: "Background recording requires the app to stay in the foreground briefly after you start. If it cuts off, re-try from the keyboard.",
                        showDivider: true
                    )
                    troubleshootingRow(
                        question: "Model didn't download",
                        answer: "Check Wi-Fi. The speech model is 1.25 GB; the AI rewriter is 2.4 GB. Both require Wi-Fi by default.",
                        showDivider: true
                    )
                    troubleshootingRow(
                        question: "Wrong words",
                        answer: "Add vocabulary words in Settings → Vocabulary. Names, technical terms, etc.",
                        showDivider: false
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func troubleshootingRow(
        question: String,
        answer: String,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            DisclosureGroup {
                Text(answer)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            } label: {
                Text(question)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.jotInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            }
            .tint(Color.jotMute)
            .padding(.horizontal, 8)

            if showDivider {
                Divider()
                    .overlay(Color.jotMuteWeak.opacity(0.45))
                    .padding(.leading, 12)
            }
        }
    }

    // MARK: - Contact

    private var contactSection: some View {
        editorialSection(title: "Contact") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Found a bug or have a feature idea? Email us — we read every message.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    if let url = URL(string: "mailto:feedback@jot.app?subject=Jot%20iOS%20Feedback") {
                        openURL(url)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.jotAccent)
                        Text("feedback@jot.app")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.jotAccent)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.jotAccent.opacity(0.7))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Email feedback at feedback@jot.app")
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Text("Jot · made on-device, made for you.")
            .font(.custom(JotType.frauncesItalicText, size: 13))
            .foregroundStyle(Color.jotMute)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    // MARK: - Building blocks

    /// SECTION_LABEL + Liquid Glass card pair shared across the Getting
    /// started / AI rewrite / Privacy / Contact sections. Centralized so a
    /// rhythm tweak ripples through every section uniformly.
    ///
    /// `content` is marked `@escaping` because `GlassCard`'s initializer
    /// stores its closure for deferred re-invocation by SwiftUI's body
    /// resolver, and the compiler propagates that escapability requirement
    /// out through this wrapper.
    @ViewBuilder
    private func editorialSection<Content: View>(
        title: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 16) {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Bullet-style paragraph with an optional bolded run inserted between
    /// the leading and trailing copy. We hand-roll the bullet chrome (no
    /// `Label` / `List`) so the dot aligns to the first-line baseline of
    /// the body text inside a glass card.
    @ViewBuilder
    private func bulletParagraph(
        _ leading: String,
        boldRun: String? = nil,
        _ trailing: String = ""
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(Color.jotAccent.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 7)

            (
                Text(leading)
                + (boldRun.map { Text($0).fontWeight(.semibold) } ?? Text(""))
                + Text(trailing)
            )
            .font(.system(size: 15))
            .foregroundStyle(Color(red: 0.357, green: 0.357, blue: 0.396))
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview("Sheet") {
    HelpView(isModal: true)
}

#Preview("Pushed") {
    NavigationStack {
        HelpView()
    }
}
