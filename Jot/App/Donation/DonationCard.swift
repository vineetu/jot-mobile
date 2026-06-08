import SwiftUI
import UIKit

/// Home-screen card surfaced once the cumulative dictation duration crosses
/// the donation threshold (see `DictationStats.donationThresholdSeconds`).
/// Dismissible. Renders inline above the transcript list — flows past on
/// scroll so it never blocks the user's primary workflow.
///
/// Copy here is **deliberately impersonal**. Unlike the Mac app, which
/// signs the pitch as "charities I support", the iOS card never references
/// the maintainer in first person — the user explicitly asked us to keep
/// the framing grounded and not promote anyone's personal advocacy. The
/// causes themselves live on the donations page, where the user can see
/// them and decide.
struct DonationCard: View {
    /// User tapped "Maybe later" — bubble up so the parent can flip its
    /// visibility @State and avoid a wasted re-read of UserDefaults.
    var onDismiss: () -> Void
    /// User tapped "See donations" — same reason as `onDismiss`, plus the
    /// parent opens the URL (we don't reach for UIApplication.shared here).
    var onSeeDonations: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jot is free, and stays free.")
                .font(.system(.title3, weight: .semibold))
                .foregroundStyle(Color.jotInk)

            Text("No accounts, no ads, nothing leaves your phone. If it's been useful, the donations page lists charities you can support.")
                .font(.system(.subheadline))
                .foregroundStyle(Color.jotMute)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                // Soft tinted blue capsule — the donation card is a gentle
                // reminder, not a primary action. A loud gradient + drop
                // shadow (originally coral, briefly blue) made this CTA
                // compete with the Dictate FAB for visual weight, which is
                // wrong for the moment. Same aesthetic as the category chip
                // in TranscriptDetailView: subtle tinted background, deep
                // blue text, no shadow. Adapts to light/dark via fixed-RGB
                // blue at low opacity — reads in both schemes.
                Button(action: onSeeDonations) {
                    HStack(spacing: 6) {
                        Text("See donations")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .font(.system(.callout, weight: .semibold))
                    .foregroundStyle(Color.jotBlueBottom)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.jotBlueTop.opacity(0.15))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("See donations")
                .accessibilityHint("Opens the Jot donations page in your browser")

                Button("Not now", action: onDismiss)
                    .font(.system(.callout))
                    .foregroundStyle(Color.jotMute)
                    .buttonStyle(.plain)
                    .accessibilityHint("Dismisses this card permanently")

                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.jotInk.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.jotInk.opacity(0.10), lineWidth: 0.5)
        )
    }
}

#Preview {
    DonationCard(onDismiss: {}, onSeeDonations: {})
        .padding()
        .background(JotDesign.background)
}
