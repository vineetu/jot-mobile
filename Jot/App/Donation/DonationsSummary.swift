import Foundation

struct DonationsSummary: Codable, Equatable, Sendable {
    let totalDonations: Int
    let totalRaisedUSD: Double
    let perCharity: [DonationCharity]
    let lastUpdated: Date

    enum CodingKeys: String, CodingKey {
        case totalDonations = "total_donations"
        case totalRaisedUSD = "total_raised_usd"
        case perCharity = "per_charity"
        case lastUpdated = "last_updated"
    }
}

struct DonationCharity: Codable, Equatable, Hashable, Identifiable, Sendable {
    let slug: String
    let name: String
    /// One-line charity description from the donations API (e.g.
    /// "Supports children in foster care with essentials and
    /// resources."). Optional because a small number of charities in
    /// the feed (e.g. "techleapindia") ship without one — the row
    /// renders without the description line in that case rather than
    /// substituting placeholder copy.
    let description: String?
    /// Direct URL to the charity's specific Jot fundraiser page on
    /// every.org (e.g. `https://www.every.org/fosterlove/f/kids-in-
    /// foster-care`). Optional for the same reason as `description`
    /// — a charity without an active fundraiser entry simply omits it.
    /// NOT currently used by the donate-pill URL builder, which
    /// constructs `/<slug>/donate?amount=N` — see `openDonation` in
    /// `DonationsView`. There's an open question whether donations
    /// through the generic `/donate` URL count toward Jot's tracker
    /// (which is keyed on the fundraiser page); flagged as a
    /// follow-up.
    let fundraiserURL: String?
    /// Direct URL to the charity's logo image (PNG/JPG/SVG served by the
    /// donations API). Optional — for charities without a logo the
    /// avatar falls back to a tinted initials chip (see
    /// `CharityAvatar`). Loaded async via `AsyncImage` at both list-row
    /// (40pt) and detail-sheet (72pt) sizes.
    let logoURL: String?
    let count: Int
    let totalRaisedUSD: Double

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case description
        case fundraiserURL = "fundraiser_url"
        case logoURL = "logo_url"
        case count
        case totalRaisedUSD = "total_raised_usd"
    }
}
