import Foundation
import os

/// Drains the "Send to Jot" Share Extension's `PendingShares/` queue.
///
/// A share extension cannot transcribe (Parakeet would get it memory-killed —
/// see `docs/share-audio-to-jot/design.md`), so it only stages the shared audio
/// bytes into the App Group. The main app turns each staged file into a
/// transcript the next time it naturally foregrounds — Model B: the extension
/// never opens the app, so this is the SOLE path from a shared file to a saved
/// transcript. Triggered from `JotApp` on every `scenePhase == .active`.
///
/// Reuses the exact pipeline the watch-sync path uses
/// (`TranscriptionService.shared.transcribe(audioFileURL:)` →
/// `TranscriptStore.append`, which itself refreshes the keyboard mirror, posts
/// `historyMirrorUpdated`, and kicks `TranscriptIndexer`).
enum PendingShareDrainer {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "PendingShareDrainer"
    )
    @MainActor private static var isDraining = false

    /// Transcribe + save every staged share (oldest first), deleting each file
    /// once its transcript is saved. Re-entrancy-guarded (a second foreground
    /// mid-drain no-ops) and deferred while a live recording is in flight so it
    /// never contends with the user's own dictation on the shared
    /// `@MainActor` `TranscriptionService`. A transcribe failure leaves that
    /// file in place to retry on the next foreground.
    @MainActor
    static func drain() {
        guard !isDraining else { return }
        // Don't fight a live dictation for the (serial, @MainActor) transcriber;
        // the queue is durable and will drain on the next foreground.
        guard !RecordingService.shared.isRecording else { return }
        guard let dir = AppGroup.pendingSharesDirectory() else { return }

        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let queue = files
            .filter { !$0.hasDirectoryPath }
            .sorted { modDate($0) < modDate($1) }
        guard !queue.isEmpty else { return }

        isDraining = true
        log.info("draining \(queue.count) shared audio file(s)")
        Task {
            defer { isDraining = false }
            for url in queue {
                await transcribeAndSave(url)
            }
        }
    }

    @MainActor
    private static func transcribeAndSave(_ url: URL) async {
        do {
            let text = try await TranscriptionService.shared.transcribe(audioFileURL: url)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                log.error("shared audio \(url.lastPathComponent, privacy: .public) transcribed empty — discarding")
            } else {
                // `transcribe(audioFileURL:)` already ran the full inference
                // pipeline (vocabulary rescore + filler-cleanup + ITN). What it
                // does NOT do — and what the in-app/keyboard pipeline applies
                // but the watch + file paths historically skipped — is the
                // readability cleanup pass (Apple Intelligence: punctuation,
                // casing, grammar). Run it here so a shared transcript reads
                // like a keyboard one. Honor the user's Automatic Cleanup
                // setting; tolerant fallback to raw (cleanup is an enhancement,
                // never a gate that could lose the transcript).
                let settings = CleanupSettings.load()
                var cleaned: String?
                if settings.enabled {
                    cleaned = try? await CleanupService().clean(
                        transcript: text,
                        instructions: settings.instructions
                    )
                }
                _ = try TranscriptStore.append(raw: text, cleaned: cleaned, source: "share")
                log.info("saved shared transcript from \(url.lastPathComponent, privacy: .public) (\(trimmed.count) chars, cleaned=\(cleaned != nil))")
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            // Leave the file staged — it retries on the next foreground.
            log.error("transcribe of shared audio \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
