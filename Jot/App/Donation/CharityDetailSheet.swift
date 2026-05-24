import SwiftUI

struct CharityAvatar: View {
    let charity: DonationCharity
    let size: CGFloat

    private var cornerRadius: CGFloat { max(6, size * 0.18) }

    private var initials: String {
        let words = charity.name.split(separator: " ").filter { !$0.isEmpty }
        guard let first = words.first?.first else { return "?" }
        if words.count >= 2, let second = words.dropFirst().first?.first {
            return "\(first)\(second)".uppercased()
        }
        return String(first).uppercased()
    }

    var body: some View {
        Group {
            if let urlString = charity.logoURL,
               !urlString.isEmpty,
               let url = URL(string: urlString) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.08)
                    case .empty, .failure:
                        fallbackChip
                    @unknown default:
                        fallbackChip
                    }
                }
            } else {
                fallbackChip
            }
        }
        .frame(width: size, height: size)
        .background(Color.jotInk.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.jotInk.opacity(0.10), lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private var fallbackChip: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold, design: .default))
            .foregroundStyle(Color.jotPageInkSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CharityDetailSheet: View {
    let charity: DonationCharity
    let onDonate: (Int) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                CharityAvatar(charity: charity, size: 72)
                    .padding(.top, 8)

                Text(charity.name)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(Color.jotPageInk)
                    .multilineTextAlignment(.center)
                    .tracking(-0.4)
                    .fixedSize(horizontal: false, vertical: true)

                if charity.count > 0 || charity.totalRaisedUSD > 0 {
                    Text(metricsText)
                        .font(.system(size: 13, weight: .regular, design: .default))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .multilineTextAlignment(.center)
                }

                if let description = charity.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 15, weight: .regular, design: .default))
                        .foregroundStyle(Color.jotPageInk)
                        .multilineTextAlignment(.leading)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 6)
                }

                HStack(spacing: 12) {
                    donateButton(amount: 2)
                    donateButton(amount: 10)
                }
                .padding(.top, 14)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .background(WallpaperBackground().ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var metricsText: String {
        let raised = formatCurrency(charity.totalRaisedUSD)
        let suffix = charity.count == 1 ? "donation" : "donations"
        return "\(raised) raised through Jot · \(charity.count) \(suffix)"
    }

    private func donateButton(amount: Int) -> some View {
        Button {
            onDonate(amount)
        } label: {
            Text("Donate $\(amount)")
                .font(.system(size: 15, weight: .semibold, design: .default))
                .foregroundStyle(Color.white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Color.jotBlueTop, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Donate \(amount) dollars to \(charity.name)")
    }

    private func formatCurrency(_ amount: Double) -> String {
        if amount.rounded() == amount {
            return "$\(Int(amount))"
        }
        return amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }
}
