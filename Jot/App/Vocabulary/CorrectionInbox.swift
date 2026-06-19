import SwiftData
import SwiftUI

/// **Drains keyboard correction verdicts into the main-app stores.**
/// The keyboard quick-review enqueues `(transcriptID, recordKey, verdict)` events
/// while the owner is in another app. When Jot next becomes active, this drains
/// them and replays each through `CorrectionReviewModel.pick` — the SAME path the
/// in-app marks/bubble/accordion use — so the text edit + per-occurrence verdict
/// + reversible mapping learning all happen identically, no duplicated logic.
enum CorrectionInbox {
    @MainActor
    static func drain(modelContext: ModelContext) async {
        let events = CorrectionBridge.peekVerdicts()
        guard !events.isEmpty else { return }
        for event in events {
            guard let transcript = fetchTranscript(id: event.transcriptID, modelContext: modelContext)
            else { continue }
            let model = CorrectionReviewModel(transcript: transcript, modelContext: modelContext)
            await model.reload()
            guard let record = model.record(forKey: event.recordKey) else { continue }
            // Skip if already adjudicated in-app since the keyboard event was queued.
            if model.verdict(of: record) != nil { continue }
            if event.verdict == "suppress" {
                // "Stop asking" from the hold deck: hard-suppress the pair from
                // keyboard asks, and keep the original (resolve the occurrence).
                await CorrectionStore.shared.suppressBlock(
                    originalWord: record.originalWord, term: record.term)
                await model.pick(record, choice: "original")
            } else {
                await model.pick(record, choice: event.verdict)
            }
        }
        // Remove exactly what we applied; a crash before here leaves the queue for
        // a safe retry, and any verdict enqueued during apply is preserved.
        CorrectionBridge.removeVerdicts(count: events.count)
    }

    @MainActor
    private static func fetchTranscript(id: UUID, modelContext: ModelContext) -> Transcript? {
        var descriptor = FetchDescriptor<Transcript>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}
