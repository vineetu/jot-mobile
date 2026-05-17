import Foundation

enum RecentsFormatting {
    static func timeText(for transcript: Transcript) -> String {
        transcript.createdAt.formatted(date: .omitted, time: .shortened)
    }

    static func durationText(for transcript: Transcript) -> String? {
        guard let duration = transcript.durationSeconds else { return nil }
        let total = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    static func dictationCountText(_ count: Int) -> String {
        count == 1 ? "1 dictation" : "\(count) dictations"
    }
}
