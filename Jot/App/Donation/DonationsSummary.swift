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
    let count: Int
    let totalRaisedUSD: Double

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case count
        case totalRaisedUSD = "total_raised_usd"
    }
}
