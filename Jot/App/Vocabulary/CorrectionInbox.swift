import JotVocabCore
import SwiftData
import SwiftUI

/// **Drains keyboard correction verdicts into the main-app stores.**
/// The keyboard quick-review enqueues `(transcriptID, recordKey, verdict)` events
/// while the owner is in another app. The app drains them as soon as the keyboard
/// pings (`correctionVerdictQueued`) or, if it wasn't running, when it next
/// becomes active, and replays each through `CorrectionReviewModel.pick` — the SAME path the
/// in-app marks/bubble/accordion use — so the text edit + per-occurrence verdict
/// + the one `VocabularyLearning.apply` (term / alt0 → `.correct`, keep and
/// "Stop asking" → `.keepOriginal`, receipt stored for the review list's Undo)
/// all happen identically, no duplicated logic. A card that timed out enqueues
/// nothing, so it teaches nothing.
enum CorrectionInbox {
    @MainActor
    static func drain(modelContext: ModelContext) async {
        // Two triggers can overlap (the keyboard's "verdict queued" ping and
        // the foreground drain). One pass at a time: an overlapping call asks
        // the running pass to go round again instead of applying — and then
        // `removeVerdicts(count:)`-ing — the same events twice.
        if isDraining { drainAgain = true; return }
        isDraining = true
        defer { isDraining = false }
        repeat {
            drainAgain = false
            await drainOnce(modelContext: modelContext)
        } while drainAgain
    }

    @MainActor private static var isDraining = false
    @MainActor private static var drainAgain = false

    @MainActor
    private static func drainOnce(modelContext: ModelContext) async {
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
                // An answered pair is never asked again (Windows handoff §1.2d:
                // "Ask answers go through SetVerdict → Adjust, then
                // SuppressBlock(pair)"). The answer itself is what's learned: a
                // confirm adds the heard form as a sounds-like on the term (the
                // decoder pair / gate evidence — never an auto-replace), a "keep
                // original" pauses the pair so the gate blocks it. Asking again only repeats
                // a question the owner already settled. Keyboard-only — the
                // transcript review still shows every occurrence.
                await CorrectionStore.shared.suppressBlock(
                    originalWord: record.originalWord, term: record.term)
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
