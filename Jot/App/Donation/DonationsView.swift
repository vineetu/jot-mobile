import SwiftUI

struct DonationsView: View {
    private static let personalizationThresholdSeconds: TimeInterval = 5 * 60

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @AppStorage("jot.donations.lastSummary") private var cachedSummaryData: Data = Data()

    @State private var summary: DonationsSummary?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var shuffledOrder: [String] = []
    @State private var searchText = ""

    var body: some View {
        ZStack {
            WallpaperBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    topToolbar
                    heroTitle
                    gratitudeBlock
                    searchBar

                    if let errorMessage, summary != nil {
                        Text(errorMessage)
                            .font(.system(size: 12, weight: .regular, design: .default))
                            .foregroundStyle(Color.jotMute)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    charityListCard
                    totalRaisedCard
                    footnote
                }
                .padding(.horizontal, JotDesign.Spacing.pageGutter)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .scrollContentBackground(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .refreshable {
                await refresh()
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .enableInteractivePopGesture()
        .task {
            guard summary == nil else { return }
            loadCachedSummary()
            await refresh()
        }
    }

    private var topToolbar: some View {
        HStack {
            glassCircleButton(
                systemImage: "chevron.backward",
                accessibilityLabel: "Back"
            ) {
                dismiss()
            }

            Spacer(minLength: 8)
        }
        .frame(minHeight: 44)
    }

    private var heroTitle: some View {
        Text("Donations.")
            .font(JotType.displaySerif(44))
            .tracking(-1.6)
            .foregroundStyle(Color.jotPageInk)
            .accessibilityAddTraits(.isHeader)
    }

    private var gratitudeBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Jot is free, and always will be.")
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundStyle(Color.jotPageInk)

            Text("The time and clarity it gives back — speaking instead of typing,\nthinking out loud, catching what would've slipped — isn't something\neveryone has access to.")
                .font(.system(size: 15, weight: .regular, design: .default))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            if let personalizationText {
                Text(personalizationText)
                    .font(.system(size: 15, weight: .semibold, design: .default))
                    .foregroundStyle(Color.jotPageInk)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("If it's helped, consider passing some of that forward.")
                .font(.system(size: 15, weight: .regular, design: .default))
                .foregroundStyle(Color.jotPageInkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }

    private var personalizationText: String? {
        guard DictationStats.totalSeconds >= Self.personalizationThresholdSeconds else {
            return nil
        }
        let savedSeconds = DictationStats.totalSeconds * DictationStats.timeSavedMultiplier
        return "Jot has saved you about \(DictationStatsRow.formatDuration(savedSeconds)) so far."
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.jotPageInkSecondary)
            TextField(
                "",
                text: $searchText,
                prompt: Text("Search charities")
                    .foregroundStyle(Color.jotPageInkSecondary)
            )
            .font(.system(size: 15))
            .foregroundStyle(Color.jotPageInk)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
            .submitLabel(.search)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Color.jotPageInkSecondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .accessibilityLabel("Search charities")
    }

    private var charityListCard: some View {
        LiquidGlassCard(paddingH: 0, paddingV: 0) {
            Group {
                if summary == nil, isLoading {
                    loadingState
                } else if summary == nil {
                    emptyErrorState
                } else if filteredCharities.isEmpty {
                    noMatchesState
                } else {
                    charityRows
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var charityRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(filteredCharities.enumerated()), id: \.element.slug) { index, charity in
                charityRow(charity)

                if index != filteredCharities.count - 1 {
                    Divider()
                        .overlay(Color.jotPageSeparator)
                        .padding(.leading, 18)
                }
            }
        }
    }

    private func charityRow(_ charity: DonationCharity) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(charity.name)
                    .font(JotType.rowTitle)
                    .tracking(-0.2)
                    .foregroundStyle(Color.jotPageInk)
                    .lineLimit(2)

                Text("\(formatCurrency(charity.totalRaisedUSD)) raised · \(donationCountText(charity.count))")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(Color.jotPageInkSecondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                donationPill(amount: 2, charity: charity)
                donationPill(amount: 10, charity: charity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
    }

    private func donationPill(amount: Int, charity: DonationCharity) -> some View {
        Button {
            openDonation(amount: amount, charity: charity)
        } label: {
            Text("$\(amount)")
                .font(.system(size: 13, weight: .semibold, design: .default))
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Color.jotBlueTop, in: Capsule(style: .continuous))
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Donate \(amount) dollars to \(charity.name)")
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(Color.jotBlueTop)

            Text("Loading charities")
                .font(.system(size: 14, weight: .regular, design: .default))
                .foregroundStyle(Color.jotPageInkSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 52)
        .accessibilityElement(children: .combine)
    }

    private var emptyErrorState: some View {
        VStack(spacing: 12) {
            Text("Couldn't load — try again")
                .font(.system(size: 17, weight: .semibold, design: .default))
                .foregroundStyle(Color.jotPageInk)
                .multilineTextAlignment(.center)

            Button {
                Task { await refresh() }
            } label: {
                Text("Retry")
                    .font(.system(size: 14, weight: .semibold, design: .default))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 18)
                    .frame(minHeight: 44)
                    .background(Color.jotBlueTop, in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Attempts to reload donation totals")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.vertical, 52)
    }

    private var noMatchesState: some View {
        Text("No matches")
            .font(.system(size: 17, weight: .semibold, design: .default))
            .foregroundStyle(Color.jotPageInk)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 18)
            .padding(.vertical, 52)
    }

    private var totalRaisedCard: some View {
        LiquidGlassCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.map { formatCurrency($0.totalRaisedUSD) } ?? "—")
                    .font(.system(size: 36, weight: .semibold, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(Color.jotPageInk)
                    .tracking(-1.0)

                Text(summary.map { "raised through Jot · \(supporterCountText($0.totalDonations))" } ?? "raised through Jot · — supporters")
                    .font(.system(size: 12, weight: .regular, design: .default))
                    .foregroundStyle(Color.jotPageInkSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroAccessibilityLabel)
    }

    private var footnote: some View {
        Text(footnoteText)
            .font(.system(size: 12, weight: .regular, design: .default))
            .foregroundStyle(Color.jotMute)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footnoteText: String {
        guard let summary else {
            return "Donations process through Every.org. Last updated —."
        }
        return "Donations process through Every.org. Last updated \(relativeUpdatedText(for: summary.lastUpdated))."
    }

    private var heroAccessibilityLabel: String {
        guard let summary else {
            return "Donation totals unavailable"
        }
        return "\(formatCurrency(summary.totalRaisedUSD)) raised through Jot, \(supporterCountText(summary.totalDonations))"
    }

    private var orderedCharities: [DonationCharity] {
        guard let summary else { return [] }
        let charitiesBySlug = Dictionary(uniqueKeysWithValues: summary.perCharity.map { ($0.slug, $0) })
        let ordered = shuffledOrder.compactMap { charitiesBySlug[$0] }
        let orderedSlugs = Set(ordered.map(\.slug))
        return ordered + summary.perCharity.filter { !orderedSlugs.contains($0.slug) }
    }

    private var filteredCharities: [DonationCharity] {
        guard !searchText.isEmpty else { return orderedCharities }
        return orderedCharities.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    @MainActor
    private func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let fetchedSummary = try await DonationsService.fetchSummary()
            applySummary(fetchedSummary)
            cacheSummary(fetchedSummary)
            errorMessage = nil
        } catch {
            if summary == nil {
                loadCachedSummary()
            }
            errorMessage = summary == nil
                ? "Couldn't load — try again"
                : "Couldn't refresh — showing last known totals"
        }
    }

    private func loadCachedSummary() {
        guard summary == nil,
              let cachedSummary = DonationsService.decodeCachedSummary(from: cachedSummaryData) else {
            return
        }
        applySummary(cachedSummary)
    }

    private func cacheSummary(_ summary: DonationsSummary) {
        guard let data = DonationsService.encodeForCache(summary) else { return }
        cachedSummaryData = data
    }

    private func applySummary(_ nextSummary: DonationsSummary) {
        summary = nextSummary
        updateShuffledOrder(for: nextSummary.perCharity)
    }

    private func updateShuffledOrder(for charities: [DonationCharity]) {
        let incomingSlugs = charities.map(\.slug)
        guard !incomingSlugs.isEmpty else {
            shuffledOrder = []
            return
        }

        if shuffledOrder.isEmpty {
            shuffledOrder = incomingSlugs.shuffled()
            return
        }

        let incomingSet = Set(incomingSlugs)
        var nextOrder = shuffledOrder.filter { incomingSet.contains($0) }
        let knownSlugs = Set(nextOrder)
        let newSlugs = incomingSlugs.filter { !knownSlugs.contains($0) }.shuffled()
        nextOrder.append(contentsOf: newSlugs)
        shuffledOrder = nextOrder
    }

    private func openDonation(amount: Int, charity: DonationCharity) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.every.org"
        components.path = "/\(charity.slug)/donate"
        components.queryItems = [
            URLQueryItem(name: "amount", value: "\(amount)")
        ]

        guard let url = components.url else { return }
        openURL(url)
    }

    private func donationCountText(_ count: Int) -> String {
        "\(count) donation\(count == 1 ? "" : "s")"
    }

    private func supporterCountText(_ count: Int) -> String {
        "\(count) supporter\(count == 1 ? "" : "s")"
    }

    private func formatCurrency(_ amount: Double) -> String {
        if amount.rounded() == amount {
            return "$\(Int(amount))"
        }
        return amount.formatted(.currency(code: "USD").precision(.fractionLength(2)))
    }

    private func relativeUpdatedText(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 {
            return "just now"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }

        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h ago"
        }

        let days = hours / 24
        if days < 7 {
            return "\(days)d ago"
        }

        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private func glassCircleButton(
        systemImage: String,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.jotInk)
                .frame(width: 44, height: 44)
                .modifier(JotDesign.Surface.key.modifier(cornerRadius: 22))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    NavigationStack {
        DonationsView()
    }
}
