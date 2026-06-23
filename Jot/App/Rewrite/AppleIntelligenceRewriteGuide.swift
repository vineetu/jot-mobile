import SwiftUI

/// Shown when Jot's on-device rewrite model (Qwen) is NOT downloaded but the device
/// HAS Apple Intelligence (features.md §7.10). Instead of pushing the 2.5 GB download,
/// we teach the free **system Writing Tools** path: the transcript text is already
/// selectable (§3.3), so the user can select it → tap the Writing Tools item → choose
/// Rewrite / Make Concise / Proofread → Copy (or Edit here first to save the result).
///
/// Pure guidance — no engine, no model, no network. The download remains available as
/// a secondary link for users who want one-tap rewrites with their own saved prompts.
@MainActor
struct AppleIntelligenceRewriteGuide: View {

    /// Fires when the user taps "Download Jot's AI". The host dismisses this sheet and
    /// presents AI Rewrite settings (chained via `onDismiss` so two sheets don't race).
    let onDownloadJotAI: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.jotMute)
                }
                .accessibilityLabel("Close")
                Spacer()
            }
            .frame(minHeight: 28)

            sparkle.padding(.top, 2)

            Text("Rewrite with Apple Intelligence")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color.jotInk)
                .multilineTextAlignment(.center)
                .padding(.top, 14)

            Text("Built into your iPhone — no download needed.")
                .font(.system(size: 14))
                .foregroundStyle(Color.jotMute)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
                .padding(.bottom, 22)

            step(1, "**Select** the transcript text.")
            step(2, "Tap the **Writing Tools** item in the popup menu.")
            step(3, "Choose **Rewrite**, **Make Concise**, **Proofread**, and more.")
            step(4, "**Copy** the result to use it — or tap **Edit** here first to **save** it to this transcript.")

            Spacer(minLength: 16)

            VStack(spacing: 3) {
                Text("Prefer one-tap rewrites in your own prompts?")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.jotMute)
                Button {
                    onDownloadJotAI()
                    dismiss()
                } label: {
                    Text("Download Jot's AI · 2.5 GB")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.jotAccent)
                }
                .accessibilityLabel("Download Jot's AI, 2.5 gigabytes")
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WallpaperBackground())
        .presentationDetents([.fraction(0.7), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(JotDesign.Spacing.sheetRadius)
    }

    // MARK: - Pieces

    private var sparkle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.37, blue: 0.60),
                            Color(red: 0.64, green: 0.36, blue: 1.00),
                            Color(red: 0.23, green: 0.61, blue: 1.00),
                            Color(red: 0.23, green: 0.84, blue: 0.78),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 64, height: 64)
                .shadow(color: Color(red: 0.47, green: 0.31, blue: 1.0).opacity(0.4), radius: 12, x: 0, y: 6)
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(
                    Circle().fill(
                        LinearGradient(
                            colors: [Color.jotBlueTop, Color.jotBlueBottom],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                )
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.jotInk)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.bottom, 16)
    }
}
