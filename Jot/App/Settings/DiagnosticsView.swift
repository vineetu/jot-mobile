//
//  DiagnosticsView.swift
//  Jot
//
//  Cross-process diagnostic log surface. Reads the App Group ring buffer
//  maintained by both the keyboard extension and the main app and lets the
//  user copy the recent event stream back to support when reporting a bug.
//  Specifically built to triage the keyboard-stop-no-paste regression — the
//  silent-skip branches in the keyboard's auto-paste flush surface as labelled
//  rows here.
//
//  Relocated from Help → Settings → About (owner decision). The view code is a
//  verbatim lift of the former `HelpView.diagnosticsSection` (+ its state, load
//  task, Clear alert, and row/chip/formatting helpers), rehosted as a standalone
//  pushed page under Settings → About.
//

import SwiftUI

struct DiagnosticsView: View {
    // Diagnostics state. Loaded on `.task` from the App Group's
    // `DiagnosticsLog`, reversed so the newest entry sits at the top.
    // `expandedEntryID` drives the per-row tap-to-expand metadata reveal;
    // `showClearConfirm` gates the destructive Clear button behind a
    // confirmation alert.
    @State private var diagnosticsEntries: [DiagnosticsEntry] = []
    @State private var expandedEntryID: UUID?
    @State private var showClearConfirm = false
    /// Flips to `true` for ~1.5s after Copy all is tapped so the pill's label
    /// confirms the clipboard write — the silent-tap variant was flagged by UX
    /// review as ambiguous (users tend to repeat-tap when nothing visibly
    /// changes).
    @State private var diagnosticsCopiedAck = false

    var body: some View {
        ZStack {
            WizardWallpaper()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Diagnostics")
                            .font(.system(size: 32, weight: .bold, design: .default))
                            .foregroundStyle(Color.jotInk)
                            .accessibilityAddTraits(.isHeader)

                        Text("Recent events from the keyboard and main app")
                            .font(.system(size: 16, weight: .regular, design: .default))
                            .foregroundStyle(Color.jotMute)
                    }
                    .padding(.top, 4)

                    diagnosticsSection
                }
                .padding(.horizontal, JotDesign.Spacing.pageMargin)
                .padding(.top, 4)
                .padding(.bottom, 32)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Body-level task instead of section-local `.onAppear` so the
            // initial load runs once even if the section scrolls off and back
            // into view. Keyboard writes that landed while this is open will
            // only show up on next presentation — acceptable for a
            // diagnostic-handoff surface.
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


    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tap an entry for details. Copy and send to support when reporting a bug.")
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
                        // Bounded `ScrollView` so the inner list can't dominate
                        // the page. 360pt covers ~9-10 rows at typographic
                        // default — enough to scan recent activity, with
                        // overflow scrollable.
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
                            // Re-read from the App Group so writes the keyboard
                            // made while this has been on screen surface without
                            // bouncing out and back in.
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
    /// message + relative timestamp. Tappable to expand inline into the entry's
    /// metadata dictionary, rendered monospaced so UUID columns line up.
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

    /// Category-keyed chip. Three tones — green (success), amber (state change),
    /// red (silent skip) — pulled from existing JotDesign tokens to avoid
    /// introducing new palette entries for one surface.
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

    /// Short-name + tone-color mapping for the chip. Kept as a single switch so
    /// adding a new `DiagnosticsCategory` upstream surfaces as a compile error
    /// here.
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
        case .pasteVerifyDeferred: return ("VERIFY", Color.jotAccent)
        case .pasteReconnectPoll: return ("POLL", Color.jotAccent)
        case .pasteLandedViaTextDidChange: return ("PASTE/TDC", Color.jotSuccess)
        case .pasteRevertedAfterLanding: return ("REVERTED", Color.jotWarning)
        case .pasteSkipOther: return ("SKIP/?", Color.jotAccent)
        case .streamingPartialReceived: return ("STREAM", Color.jotAccent)
        case .memoryWarning: return ("MEMORY", Color.jotWarning)
        case .classifyStart: return ("CLASSIFY/START", Color.jotAccent)
        case .classifyEnd: return ("CLASSIFY/END", Color.jotAccent)
        case .classifyMemoryWarning: return ("CLASSIFY/MEM", Color.jotWarning)
        case .appUnresponsiveRecovery: return ("RECOVER", Color.jotWarning)
        case .vocabularyGate: return ("VOCAB", Color.jotAccent)
        case .tts: return ("TTS", Color.jotAccent)
        case .recordingOutcome: return ("REC", Color.jotWarning)
        case .modelLoad: return ("MODEL", Color.jotAccent)
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

    /// Serializes the entire diagnostic log as plain text for clipboard handoff.
    /// ISO-8601 timestamp keeps the format machine-parseable on the receiving
    /// side; metadata is rendered as `{k=v, k=v}` after the message so the line
    /// stays single-line per entry.
    private func formatEntriesForClipboard() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Re-read in case the in-memory buffer is stale relative to a very
        // recent keyboard write. Cheap relative to the user gesture.
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
}

#Preview {
    NavigationStack {
        DiagnosticsView()
    }
}
