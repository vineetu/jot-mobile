import Foundation

enum RewritePreset: String, CaseIterable, Identifiable, Sendable {
    case rewrite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rewrite: return "Rewrite"
        }
    }

    var prompt: String {
        Self.prompts[rawValue] ?? ""
    }

    static let prompts: [String: String] = [
        "rewrite": "Rewrite the following text to be clearer and more articulate while preserving the meaning, tone, and intent. Return only the rewritten text.",
    ]
}
