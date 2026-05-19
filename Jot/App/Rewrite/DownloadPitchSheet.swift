import SwiftUI

/// Bottom-sheet AI-download pitch (Mockup 12 / plan §6.3).
///
/// Presented from `TranscriptDetailView`'s Rewrite button when the LLM is
/// in `.notReady` — i.e. the user has tapped Rewrite but the weights aren't
/// on disk yet. Frames the 2.4 GB download as an opt-in by surfacing the
/// model name, size, and a "Maybe later" exit before kicking off the
/// `LLMClientUIAdapter.warm()` lifecycle.
///
/// ## Anatomy (plan §6.3)
///
/// - Grabber + close-X (top-right).
/// - Hero coral `IconBox(symbol: "wand.and.stars", size: 72)`.
/// - Headline "Add AI to Jot" in `JotType.editorialBody` (Fraunces).
/// - 2-sentence body that names the model + download size honestly.
/// - Primary coral-gradient "Download · <size>" pill.
/// - Secondary text "Maybe later".
///
/// ## Size + name strings
///
/// Model name and download size resolve from
/// `JotDesign.activeRewriteModelDisplayName` /
/// `JotDesign.activeRewriteModelSize`, which routes through
/// `LLMClientFactory.shared.currentProvider`. The same single source
/// drives the AI Rewrite settings page, the wizard's AI offer step,
/// and the Help screen — switch provider and every surface updates.
///
/// Sheet detent: `.height(460)` so the hero + headline + pitch + CTA all
/// land comfortably above the safe area on small devices.
struct DownloadPitchSheet: View {

    /// Model display name shown in the pitch body. Caller passes
    /// `JotDesign.activeRewriteModelDisplayName` so the sheet stays honest
    /// with the active provider.
    let modelDisplayName: String

    /// Fires when the user taps "Download". Caller is expected to invoke
    /// `LLMClientUIAdapter.warm()`. The sheet dismisses itself before the
    /// callback so the user sees the in-progress banner inside Settings
    /// rather than a stale pitch.
    let onDownload: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Resolved download size for the active provider. Read inside the
    /// view body so MainActor isolation makes `JotDesign.activeRewriteModelSize`
    /// addressable. (Previously a `static let`, which can't read a
    /// MainActor-isolated property — keep this as an instance accessor.)
    private var downloadSizeCopy: String {
        JotDesign.activeRewriteModelSize
    }

    var body: some View {
        VStack(spacing: 0) {
            topRow
                .padding(.bottom, 12)

            IconBox(
                symbol: "wand.and.stars",
                tint: Color.jotAccent,
                size: 72
            )
            .padding(.top, 4)

            Text("Add AI to Jot")
                .font(JotType.editorialBody)
                .foregroundStyle(Color.jotInk)
                .padding(.top, 18)

            Text(pitchBody)
                .font(.system(size: 15))
                .foregroundStyle(Color.jotMute)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.top, 10)
                .padding(.horizontal, 8)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(pitchBody)

            Spacer(minLength: 16)

            downloadCTA
                .padding(.bottom, 12)

            Button("Maybe later") {
                dismiss()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Color.jotMute)
            .accessibilityLabel("Dismiss download pitch")
            .padding(.bottom, 6)
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(JotDesign.background.ignoresSafeArea())
        .presentationDetents([.height(460)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
    }

    // MARK: - Top row (close-X)

    private var topRow: some View {
        HStack {
            // Left symmetry placeholder — keeps the close-X visually
            // anchored to the trailing edge regardless of font metrics.
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.clear)
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.jotMute)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.85))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.jotMuteWeak.opacity(0.30), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .frame(minHeight: 32)
    }

    // MARK: - Body copy

    /// Two-sentence pitch. Names the active model and the download size
    /// honestly so the user can make an informed decision before tapping
    /// Download pitch — leads on the three seeded defaults (Articulate, Action
    /// Items, Email) without naming them so the copy survives future preset
    /// changes.
    private var pitchBody: String {
        "\(modelDisplayName) runs on your iPhone to articulate dictation, extract action items, or draft emails — fully offline, no accounts. The first download is about \(downloadSizeCopy) over Wi-Fi."
    }

    // MARK: - Download CTA

    private var downloadCTA: some View {
        Button {
            onDownload()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text("Download · \(downloadSizeCopy)")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, 24)
            .frame(minHeight: 50)
            .frame(maxWidth: .infinity)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotAccent,
                                Color.jotAccent.opacity(0.88)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 0.5)
            )
            .shadow(color: Color.jotAccent.opacity(0.30), radius: 8, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Download \(modelDisplayName), \(downloadSizeCopy)")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    Color.gray
        .ignoresSafeArea()
        .sheet(isPresented: .constant(true)) {
            DownloadPitchSheet(
                modelDisplayName: "Qwen 3.5 4B",
                onDownload: {}
            )
        }
}
