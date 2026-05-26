//
//  FeedbackClient.swift
//  Jot
//

import Foundation

struct FeedbackPayload: Codable {
    let platform: String
    let version: String
    let message: String
    /// Base64 data URIs (e.g. `data:image/jpeg;base64,...`). Encoded
    /// upstream by `FeedbackImageEncoder`. Omitted entirely when empty
    /// so the server-side request shape stays identical to pre-screenshot
    /// builds for text-only feedback.
    let images: [String]?
}

struct FeedbackResponse: Codable {
    let status: String
    let id: Int?
    let error: String?
}

enum FeedbackError: LocalizedError {
    case empty
    case network(URLError)
    case decoding
    case rateLimited(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Please type something before sending."
        case .network: return "No connection. Check your network and try again."
        case .decoding: return "Couldn't read the response. Please try again."
        case .rateLimited(let msg): return msg
        case .server(let msg): return msg
        }
    }
}

final class FeedbackClient: Sendable {
    static let shared = FeedbackClient()
    private let endpoint = URL(string: "https://jot-donations.ideaflow.page/feedback")!
    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: cfg)
    }

    func submit(message: String, images: [String] = []) async throws -> Int {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeedbackError.empty }

        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let payload = FeedbackPayload(
            platform: "ios",
            version: version,
            message: trimmed,
            images: images.isEmpty ? nil : images
        )

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            throw FeedbackError.network(urlError)
        }

        let http = response as? HTTPURLResponse
        let statusCode = http?.statusCode ?? 0
        let decoded = try? JSONDecoder().decode(FeedbackResponse.self, from: data)
        let serverMessage = decoded?.error ?? "Something went wrong. Please try again."

        // Rate limit: HTTP 429, or error message that mentions rate
        if statusCode == 429 || (decoded?.status == "error" && (decoded?.error?.range(of: "rate", options: .caseInsensitive) != nil)) {
            throw FeedbackError.rateLimited(decoded?.error ?? "Rate limit exceeded. Please try again later.")
        }
        if !(200..<300).contains(statusCode) || decoded?.status == "error" {
            throw FeedbackError.server(serverMessage)
        }
        guard decoded?.status == "ok", let id = decoded?.id else {
            throw FeedbackError.decoding
        }
        return id
    }
}
