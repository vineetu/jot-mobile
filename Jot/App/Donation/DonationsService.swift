import Foundation

enum DonationsService {
    enum Error: Swift.Error {
        case invalidResponse
        case badStatus(Int)
    }

    private static let endpoint = URL(string: "https://jot-donations.ideaflow.page/summary")!

    static func fetchSummary(session: URLSession = .shared) async throws -> DonationsSummary {
        let (data, response) = try await session.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw Error.badStatus(httpResponse.statusCode)
        }
        return try decoder.decode(DonationsSummary.self, from: data)
    }

    static func decodeCachedSummary(from data: Data) -> DonationsSummary? {
        guard !data.isEmpty else { return nil }
        return try? decoder.decode(DonationsSummary.self, from: data)
    }

    static func encodeForCache(_ summary: DonationsSummary) -> Data? {
        try? encoder.encode(summary)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
