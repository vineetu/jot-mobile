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

    // Diagnostics section state. Loaded on body `.task` from the
    // App Group's `DiagnosticsLog`, reversed so the newest entry sits at
    // the top of the list. `expandedEntryID` drives the per-row tap-to-
    // expand metadata reveal; `showClearConfirm` gates the destructive
    // Clear button behind a confirmation alert.
    @State private var diagnosticsEntries: [DiagnosticsEntry] = []
    @State private var expandedEntryID: UUID?
    @State private var showClearConfirm = false
    /// Flips to `true` for ~1.5s after Copy all is tapped so the pill's
    /// label confirms the clipboard write — the silent-tap variant was
    /// flagged by UX review as ambiguous (users tend to repeat-tap when
    /// nothing visibly changes).
    @State private var diagnosticsCopiedAck = false

    var body: some View {
        ZStack {
            // Warm-cream wallpaper shared with the wizard. Help is a
            // read-y editorial surface, not a chrome surface, so the
            // warmer backdrop reads better than the home's grey gradient.
            WizardWallpaper()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    hero
                    useCasesSection
                    gettingStartedSection
                    aiRewriteSection
                    privacySection
                    troubleshootingSection
                    contactSection
                    diagnosticsSection
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
        .task {
            // Body-level task instead of section-local `.onAppear` so the
            // initial load runs once even if the section scrolls off and
            // back into view. Keyboard writes that landed while Help was
            // open will only show up on next presentation — acceptable for
            // a diagnostic-handoff surface.
            diagnosticsEntries = DiagnosticsLog.readAll().reversed()
        }
        .alert("Clear diagnostics?", isPresented: $showClearConfirm) {
            Button("Clear", role: .destructive) {
                DiagnosticsLog.clear()
                diagnosticsEntries = []
                expandedEntryID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone.")
        }
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

    // MARK: - What it's for (use cases)

    private var useCasesSection: some View {
        editorialSection(title: "What it's for") {
            VStack(alignment: .leading, spacing: 22) {
                useCase(
                    "Speak instead of typing, in any app",
                    Text("You're in Messages, Mail, Slack, your browser — anywhere you'd normally type. Tap the globe key on your iPhone keyboard to switch to Jot, tap Dictate, and speak. Your voice goes straight into the text field you're already in.")
                )

                useCase(
                    "Keep going when life interrupts",
                    Text("You're dictating a thought, and your phone rings. Or you need to check Calendar mid-sentence. Or someone hands you something. Jump out, come back — Jot's microphone stays warm for up to five minutes, ready to pick up where you left off. What you'd already said is saved as you said it, so even if the call drops everything, the part you'd already dictated is safe and waiting in the text field.")
                )

                useCase(
                    "Polish what you said into what you meant",
                    Text("You dictated something — a long meandering thought, a list of things to do, the bones of an email. Open it in Jot and tap one of the built-in prompts: ")
                        + Text("Articulate").fontWeight(.semibold)
                        + Text(" cleans up the prose, ")
                        + Text("Action Items").fontWeight(.semibold)
                        + Text(" pulls out the tasks, ")
                        + Text("Email").fontWeight(.semibold)
                        + Text(" formats it for sending. Or write your own prompt once and reuse it — \u{201C}Turn this into bullet points,\u{201D} \u{201C}Translate to French,\u{201D} \u{201C}Make it sound more formal\u{201D} — and run it on any transcript with a tap.")
                )
            }
        }
    }

    /// Use-case entry: a small bold title followed by a body paragraph.
    /// Body is a `Text` so callers can compose inline-bold runs (for proper
    /// names like Articulate / Action Items / Email) without dropping out
    /// to AttributedString.
    @ViewBuilder
    private func useCase(_ title: String, _ body: Text) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .fixedSize(horizontal: false, vertical: true)

            body
                .font(.system(size: 15))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
                    " icon on any transcript to clean up filler words, fix grammar, or reformat into bullet points."
                )

                bulletParagraph(
                    "Rewrites happen entirely on-device using a \(JotDesign.activeRewriteModelSize) model. Your text never leaves your iPhone."
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
                    "Optional AI rewrites are also on-device (\(JotDesign.activeRewriteModelDisplayName))."
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
                        answer: "The default speech model ships with the app — no download needed. The optional Parakeet 600M (~440 MB) and the AI rewriter (~\(JotDesign.activeRewriteModelSize)) need Wi-Fi; check your connection if any tap doesn't start.",
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
                    .foregroundStyle(Color.jotPageInkSecondary)
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

    // MARK: - Diagnostics

    /// Cross-process diagnostic log surface. Reads the App Group ring
    /// buffer maintained by both the keyboard extension and the main app
    /// and lets the user copy the recent event stream back to support
    /// when reporting a bug. Specifically built to triage the
    /// keyboard-stop-no-paste regression — the silent-skip branches in
    /// the keyboard's auto-paste flush now surface as labelled rows here.
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Diagnostics")
                .padding(.horizontal, 4)

            Text("Recent events from the keyboard and main app. Tap an entry for details. Copy and send to support when reporting a bug.")
                .font(.system(size: 15))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    if diagnosticsEntries.isEmpty {
                        Text("No diagnostics yet. Use the keyboard to dictate, then return here.")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        // Bounded `ScrollView` so the inner list can't
                        // dominate the page. 360pt covers ~9-10 rows at
                        // typographic default — enough to scan recent
                        // activity, with overflow scrollable.
                        ScrollView(.vertical, showsIndicators: true) {
                            VStack(spacing: 6) {
                                ForEach(Array(diagnosticsEntries.prefix(50))) { entry in
                                    diagnosticsRow(entry)
                                }
                            }
                        }
                        .frame(maxHeight: 360)
                    }

                    HStack(spacing: 10) {
                        Button {
                            // Re-read from the App Group so writes the
                            // keyboard made while Help has been on screen
                            // surface without bouncing out and back in.
                            diagnosticsEntries = DiagnosticsLog.readAll().reversed()
                            expandedEntryID = nil
                        } label: {
                            Text("Refresh")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.jotInk)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Refresh diagnostics")

                        Button {
                            UIPasteboard.general.string = formatEntriesForClipboard()
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                            diagnosticsCopiedAck = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                diagnosticsCopiedAck = false
                            }
                        } label: {
                            Text(diagnosticsCopiedAck ? "Copied" : "Copy all")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.jotInk)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .disabled(diagnosticsEntries.isEmpty)
                        .opacity(diagnosticsEntries.isEmpty ? 0.5 : 1.0)
                        .accessibilityLabel("Copy all diagnostics")

                        Button {
                            showClearConfirm = true
                        } label: {
                            Text("Clear")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color.jotInk)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .modifier(JotDesign.Surface.regular.modifier(cornerRadius: 18))
                        }
                        .buttonStyle(.plain)
                        .disabled(diagnosticsEntries.isEmpty)
                        .opacity(diagnosticsEntries.isEmpty ? 0.5 : 1.0)
                        .accessibilityLabel("Clear diagnostics")

                        Spacer(minLength: 0)
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Single diagnostic row. Chip (category short-name + tone color) +
    /// message + relative timestamp. Tappable to expand inline into the
    /// entry's metadata dictionary, rendered monospaced so UUID columns
    /// line up.
    @ViewBuilder
    private func diagnosticsRow(_ entry: DiagnosticsEntry) -> some View {
        let isExpanded = (expandedEntryID == entry.id)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedEntryID = isExpanded ? nil : entry.id
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    diagnosticsChip(entry.category)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("[\(entry.source)] \(entry.message)")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.jotInk)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(relativeTimestamp(entry.timestamp))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.jotMute)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let metadata = entry.metadata, !metadata.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(metadata.keys.sorted(), id: \.self) { key in
                        Text("\(key): \(metadata[key] ?? "")")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.jotPageInkSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            } else if isExpanded {
                Text("(no metadata)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.jotMute)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }

    /// Category-keyed chip. Three tones — green (success), amber (state
    /// change), red (silent skip) — pulled from existing JotDesign tokens
    /// to avoid introducing new palette entries for one surface.
    @ViewBuilder
    private func diagnosticsChip(_ category: DiagnosticsCategory) -> some View {
        let (label, tone) = diagnosticsChipMetadata(for: category)
        Text(label)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tone, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize(horizontal: true, vertical: false)
    }

    /// Short-name + tone-color mapping for the chip. Kept as a single
    /// switch so adding a new `DiagnosticsCategory` upstream surfaces as
    /// a compile error here.
    private func diagnosticsChipMetadata(
        for category: DiagnosticsCategory
    ) -> (String, Color) {
        switch category {
        case .pasteSuccess: return ("PASTE", Color.jotSuccess)
        case .publishCompleted: return ("PUBLISH", Color.jotSuccess)
        case .sessionStarted: return ("START", Color.jotWarning)
        case .sessionStopRequested: return ("STOP", Color.jotWarning)
        case .publishResolved: return ("RESOLVE", Color.jotWarning)
        case .pasteSkipNoPayload: return ("SKIP/NONE", Color.jotAccent)
        case .pasteSkipSessionMismatch: return ("SKIP/SESSION", Color.jotAccent)
        case .pasteSkipDocumentMismatch: return ("SKIP/DOC", Color.jotAccent)
        case .pasteSkipKeyboardTypeMismatch: return ("SKIP/KB", Color.jotAccent)
        case .pasteSkipNoFullAccess: return ("SKIP/FA", Color.jotAccent)
        case .pasteSkipEmptyText: return ("SKIP/EMPTY", Color.jotAccent)
        case .pasteSkipProxyDisconnected: return ("SKIP/PROXY", Color.jotAccent)
        case .pasteSkipOther: return ("SKIP/?", Color.jotAccent)
        case .streamingPartialReceived: return ("STREAM", Color.jotAccent)
        case .memoryWarning: return ("MEMORY", Color.jotWarning)
        case .classifyStart: return ("CLASSIFY/START", Color.jotAccent)
        case .classifyEnd: return ("CLASSIFY/END", Color.jotAccent)
        case .classifyMemoryWarning: return ("CLASSIFY/MEM", Color.jotWarning)
        }
    }

    /// Compact relative timestamp ("just now", "12s", "4m", "1h", "3d").
    /// Inline because there's no shared helper in the codebase and the
    /// formatting is tight enough that pulling in `RelativeDateTimeFormatter`
    /// would render too verbose ("4 minutes ago") for the right-aligned
    /// timestamp slot.
    private func relativeTimestamp(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case 0..<5: return "just now"
        case 5..<60: return "\(seconds)s"
        case 60..<3600: return "\(seconds / 60)m"
        case 3600..<86400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86400)d"
        }
    }

    /// Serializes the entire diagnostic log as plain text for clipboard
    /// handoff. ISO-8601 timestamp keeps the format machine-parseable on
    /// the receiving side; metadata is rendered as `{k=v, k=v}` after the
    /// message so the line stays single-line per entry.
    private func formatEntriesForClipboard() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Re-read in case the in-memory buffer is stale relative to a
        // very recent keyboard write. Cheap relative to the user gesture.
        let entries = DiagnosticsLog.readAll()
        return entries.map { entry in
            let ts = formatter.string(from: entry.timestamp)
            let meta: String
            if let metadata = entry.metadata, !metadata.isEmpty {
                let pairs = metadata.keys.sorted()
                    .map { "\($0)=\(metadata[$0] ?? "")" }
                    .joined(separator: ", ")
                meta = " {\(pairs)}"
            } else {
                meta = ""
            }
            return "[\(ts)] [\(entry.source)] \(entry.category.rawValue) \(entry.message)\(meta)"
        }.joined(separator: "\n")
    }

    // MARK: - Contact

    private var contactSection: some View {
        editorialSection(title: "Contact") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Found a bug or have a feature idea? Tell us — we read every message.")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                NavigationLink {
                    FeedbackView()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "envelope")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.jotAccent)
                        Text("Send feedback")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.jotAccent)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.jotAccent.opacity(0.7))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send feedback")
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
                .fill(Color.jotBlueTop.opacity(0.5))
                .frame(width: 5, height: 5)
                .padding(.top, 7)

            (
                Text(leading)
                + (boldRun.map { Text($0).fontWeight(.semibold) } ?? Text(""))
                + Text(trailing)
            )
            .font(.system(size: 15))
            .foregroundStyle(Color.jotPageInkSecondary)
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
