import SwiftUI
import UIKit

/// Ephemeral translate sheet (features.md §3.9). Opened from the
/// [Rewrite picker](RewritePickerSheet.swift)'s "Translate" row. Pick a language
/// → on-device Apple Translation (via `TranslationGateway`, the same engine the
/// TTS Lab uses) → Copy / Share. Nothing is saved to the transcript — this is a
/// read-once surface, so there is no schema impact and no Rewrite-slot conflict.
///
/// The single `TranslationTaskHost` that fulfils `TranslationGateway`'s session
/// lives in the presenting `TranscriptDetailView` (mounted unconditionally), and
/// stays alive while this sheet is up — so we must NOT mount a second host here
/// (two hosts would resume the same continuation twice and crash).
@MainActor
struct TranslateSheet: View {

    /// The text to translate — the active tab's body (Original or Rewrite),
    /// captured at present time.
    let text: String

    @Environment(\.dismiss) private var dismiss

    @State private var selected: String?
    @State private var result: String = ""
    @State private var isTranslating = false
    @State private var didCopy = false

    private struct Lang: Identifiable { let code: String; let name: String; var id: String { code } }

    /// Common targets shown as chips. Apple's Translation framework supports
    /// more; this curated set covers the overwhelming majority of use and keeps
    /// the sheet a one-tap surface. (A "More…" full picker can come later.)
    private let languages: [Lang] = [
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "ru", name: "Russian"),
        .init(code: "nl", name: "Dutch"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            header

            Text("Translate to")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(Color.jotPageInkCaption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 18)
                .padding(.bottom, 10)

            languageChips

            resultArea
                .padding(.top, 18)

            Spacer(minLength: 12)

            if !result.isEmpty && !isTranslating {
                actions
                    .padding(.bottom, 14)
            }

            Text("Translated on your iPhone — your text never leaves the device.")
                .font(.system(size: 12))
                .foregroundStyle(Color.jotMute)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WallpaperBackground())
        .presentationDetents([.fraction(0.6), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jotMute)
            }
            .accessibilityLabel("Close translate")

            Spacer()

            Text("Translate")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Spacer()

            // Symmetry spacer so the title stays centered.
            Image(systemName: "xmark")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.clear)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 32)
    }

    // MARK: - Language chips

    private var languageChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(languages) { lang in
                    let isSel = selected == lang.code
                    Button { translate(to: lang.code) } label: {
                        Text(lang.name)
                            .font(.system(size: 14, weight: isSel ? .semibold : .regular))
                            .foregroundStyle(isSel ? Color.white : Color.jotInk)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 8)
                            .background(chipBackground(isSel))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Translate to \(lang.name)")
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func chipBackground(_ selected: Bool) -> some View {
        if selected {
            Capsule().fill(
                LinearGradient(
                    colors: [Color.jotBlueTop, Color.jotBlueBottom],
                    startPoint: .top, endPoint: .bottom
                )
            )
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var resultArea: some View {
        if isTranslating {
            HStack(spacing: 10) {
                ProgressView()
                Text("Translating…")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.jotMute)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 28)
        } else if !result.isEmpty {
            ScrollView {
                Text(result)
                    .font(.system(size: 18, design: .serif))
                    .italic()
                    .lineSpacing(3)
                    .foregroundStyle(Color.jotInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
        } else {
            Text("Pick a language to translate this transcript.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotMute)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 28)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                UIPasteboard.general.string = result
                didCopy = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { didCopy = false }
            } label: {
                Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(
                                colors: [Color.jotBlueTop, Color.jotBlueBottom],
                                startPoint: .top, endPoint: .bottom
                            ))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(didCopy ? "Copied translation" : "Copy translation")

            ShareLink(item: result) {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
            }
            .accessibilityLabel("Share translation")
        }
    }

    // MARK: - Translate

    private func translate(to code: String) {
        selected = code
        isTranslating = true
        result = ""
        didCopy = false
        let source = text
        Task {
            let out = await TranslationGateway.shared.translate(source, to: code)
            await MainActor.run {
                result = out
                isTranslating = false
            }
        }
    }
}
