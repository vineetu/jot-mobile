//
//  HelpView.swift
//  Jot
//
//  Redesigned Help surface. Editorial chrome — warm-cream wallpaper (shared
//  with the wizard), Fraunces display header, Liquid Glass cards. Presented two
//  ways:
//    1. As a navigation push from Settings → ABOUT → "Help & Support".
//    2. As a modal sheet from the home header's "?" glass-circle button.
//
//  Both entry points render the same content. The view picks its dismiss
//  affordance based on `isModal` — in modal presentation we surface a Done pill
//  that calls `dismiss()`; pushed from Settings, the native nav back button
//  handles dismissal.
//
//  Navigation: HelpView already sits inside an ambient NavigationStack in BOTH
//  paths (the home modal wraps it; Settings provides its own). The two sub-pages
//  ("How Jot works", "See for yourself.") push with plain `NavigationLink`s on
//  that ambient stack — same as the existing Send-feedback link. No internal
//  stack wrapper.
//
//  Content order: WHAT JOT DOES (4-row expandable feature card) → GETTING
//  STARTED (push) → TROUBLESHOOTING (4-row accordion) → PRIVACY (push) → Send
//  feedback. Diagnostics moved to Settings → About.
//

import SwiftUI

/// Identifiers for the "What Jot does" feature accordion (one-open).
private enum HelpFeature: Hashable {
    case speak, keepGoing, polish, ask
}

/// Identifiers for the Troubleshooting accordion (multi-open).
private enum HelpQuestion: Hashable {
    case paste, cutOff, model, wrongWords
}

/// Standalone help screen. Use `HelpView()` for nav-push from Settings;
/// `HelpView(isModal: true)` to show a Done pill in the top-right when
/// presented as a sheet from the home header.
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    /// `true` when presented via `.sheet(...)`. Controls whether the editorial
    /// header surfaces a glass "Done" pill (sheet path) or relies on the nav
    /// stack's native back button (push path).
    var isModal: Bool = false

    /// "What Jot does" — one-open feature accordion (tight, focused).
    @State private var expandedFeature: HelpFeature?
    /// Troubleshooting — multi-open accordion, all collapsed initially.
    @State private var expandedQuestions: Set<HelpQuestion> = []

    var body: some View {
        ZStack {
            // Warm-cream wallpaper shared with the wizard. Help is a read-y
            // editorial surface, not a chrome surface, so the warmer backdrop
            // reads better than the home's grey gradient.
            WizardWallpaper()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    whatJotDoesSection
                    gettingStartedSection
                    troubleshootingSection
                    privacySection
                    sendFeedbackSection
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, isModal ? 8 : 4)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        // Only hide the nav bar when we're the root of our own modal stack.
        // When pushed from Settings, we keep the system nav bar so the back
        // chevron stays visible.
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
                    // affordance. Hidden on the nav-push path because the system
                    // back button is already present.
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

    // MARK: - What Jot does (4-row expandable feature card)

    private var whatJotDoesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("What Jot does")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 0) {
                VStack(spacing: 0) {
                    featureRow(
                        .speak,
                        systemImage: "keyboard",
                        tint: JotDesign.JotSemanticIcon.speechModel,
                        shaded: JotDesign.JotSemanticIcon.speechModelShaded,
                        title: "Speak instead of typing, in any app",
                        body: "Switch to the Jot keyboard, tap Jot down, talk. Your words land in the field you're in.",
                        showDivider: true
                    )
                    featureRow(
                        .keepGoing,
                        systemImage: "arrow.clockwise",
                        tint: JotDesign.JotSemanticIcon.privacyMicReady,
                        shaded: JotDesign.JotSemanticIcon.privacyMicReadyShaded,
                        title: "Keep going when life interrupts",
                        body: "Calls, app switches — the mic stays warm for five minutes, and what you said is already saved. Even if a call drops everything, the part you'd already dictated is safe in the text field.",
                        showDivider: true
                    )
                    featureRow(
                        .polish,
                        systemImage: "wand.and.stars",
                        tint: JotDesign.JotSemanticIcon.ai,
                        shaded: JotDesign.JotSemanticIcon.aiShaded,
                        title: "Polish what you said into what you meant",
                        body: "Tap Articulate on any transcript — Cleanup, Action Items, Email, or a prompt you wrote. All on this iPhone.",
                        showDivider: true
                    )
                    featureRow(
                        .ask,
                        systemImage: "sparkles",
                        tint: Color.jotBlueTop,
                        shaded: Color.jotBlueBottom,
                        title: "Find your ideas by asking Jot",
                        body: "Ask in plain words — \u{201C}what did I decide about the launch?\u{201D} — and get an answer from your own notes.",
                        showDivider: false
                    )
                }
            }

            Text("Tap a feature to read how it works.")
                .font(.system(size: 12.5))
                .foregroundStyle(Color.jotMute)
                .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private func featureRow(
        _ feature: HelpFeature,
        systemImage: String,
        tint: Color,
        shaded: Color,
        title: String,
        body: String,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HelpExpandableRow(
                systemImage: systemImage,
                tint: tint,
                shaded: shaded,
                title: title,
                isExpanded: expandedFeature == feature,
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        // One-open: tapping the active row collapses; tapping
                        // another switches.
                        expandedFeature = (expandedFeature == feature) ? nil : feature
                    }
                }
            ) {
                Text(body)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showDivider {
                HelpRowDivider(inset: 16)
            }
        }
    }

    // MARK: - Getting started (pushes "How Jot works")

    private var gettingStartedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Getting started")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 0) {
                NavigationLink {
                    HowJotWorksPage()
                } label: {
                    HelpLinkRow(
                        systemImage: "book",
                        tint: JotDesign.JotSemanticIcon.helpSupport,
                        shaded: JotDesign.JotSemanticIcon.helpSupportShaded,
                        title: "How Jot works",
                        subtitle: "The 30-second refresher, animated"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("How Jot works")
                .accessibilityHint("Opens an animated walkthrough")
            }
        }
    }

    // MARK: - Troubleshooting (4-row accordion, collapsed)

    private var troubleshootingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Troubleshooting")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 0) {
                VStack(spacing: 0) {
                    questionRow(
                        .paste,
                        question: "The keyboard didn't paste",
                        answer: "Make sure Full Access is enabled. Settings → General → Keyboard → Keyboards → Jot → Allow Full Access.",
                        showDivider: true
                    )
                    questionRow(
                        .cutOff,
                        question: "My recording was cut off",
                        answer: "Background recording requires the app to stay in the foreground briefly after you start. If it cuts off, re-try from the keyboard.",
                        showDivider: true
                    )
                    questionRow(
                        .model,
                        question: "The speech model didn't download",
                        answer: "On most iPhones the speech model ships with the app — no download needed. On older iPhones a smaller speech model downloads on first use, and the AI rewriter (~\(JotDesign.activeRewriteModelSize)) downloads too — both need Wi-Fi, so check your connection if a tap doesn't start.",
                        showDivider: true
                    )
                    questionRow(
                        .wrongWords,
                        question: "It heard the wrong words",
                        answer: "Add vocabulary words in Settings → Vocabulary. Names, technical terms, etc.",
                        showDivider: false
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func questionRow(
        _ question: HelpQuestion,
        question questionText: String,
        answer: String,
        showDivider: Bool
    ) -> some View {
        VStack(spacing: 0) {
            HelpExpandableRow(
                systemImage: nil,
                title: questionText,
                titleFont: .system(size: 15.5, weight: .medium),
                isExpanded: expandedQuestions.contains(question),
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        if expandedQuestions.contains(question) {
                            expandedQuestions.remove(question)
                        } else {
                            expandedQuestions.insert(question)
                        }
                    }
                }
            ) {
                Text(answer)
                    .font(.system(size: 14.5))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if showDivider {
                HelpRowDivider(inset: 16)
            }
        }
    }

    // MARK: - Privacy (pushes "See for yourself.")

    private var privacySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Privacy")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 0) {
                NavigationLink {
                    SeeForYourselfPage()
                } label: {
                    HelpLinkRow(
                        systemImage: "checkmark.shield",
                        tint: JotDesign.JotSemanticIcon.privacyOnDevice,
                        shaded: JotDesign.JotSemanticIcon.privacyOnDeviceShaded,
                        title: "Everything happens on your iPhone",
                        subtitle: "See the proof in your App Privacy Report"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Everything happens on your iPhone")
                .accessibilityHint("Opens the privacy verification page")
            }
        }
    }

    // MARK: - Send feedback (existing FeedbackView)

    private var sendFeedbackSection: some View {
        GlassCard(tier: .regular, padding: 0) {
            NavigationLink {
                FeedbackView()
            } label: {
                HelpLinkRow(
                    systemImage: "bubble.left.and.bubble.right",
                    tint: JotDesign.JotSemanticIcon.sendFeedback,
                    shaded: JotDesign.JotSemanticIcon.sendFeedbackShaded,
                    title: "Send feedback"
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send feedback")
            .accessibilityHint("Opens the feedback form")
        }
    }
}

#Preview("Sheet") {
    NavigationStack {
        HelpView(isModal: true)
    }
}

#Preview("Pushed") {
    NavigationStack {
        HelpView()
    }
}
