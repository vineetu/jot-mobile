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
/// `historyMirrorUpdated`, and indexes the note in Core Spotlight).
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
                    cleaned = try? await RewriteClient.shared.rewrite(
                        text: text,
                        systemPrompt: settings.instructions
                    )
                }
                // Retain the shared audio (copied before the staged file is
                // removed below) so the user can re-transcribe it — the import
                // path is the main case where the language was a guess.
                let saved = try TranscriptStore.append(raw: text, cleaned: cleaned, source: "share", retainAudioFileURL: url)
                log.info("saved shared transcript from \(url.lastPathComponent, privacy: .public) (\(trimmed.count) chars, cleaned=\(cleaned != nil))")
                // Auto-diarize shared audio (headline case: a call recording
                // shared from Notes → Speakers tab). Runs on the just-staged
                // file while it's still present (removed below); an enhancement,
                // NEVER a gate — any skip/error leaves the transcript untouched.
                if let saved {
                    await autoDiarize(saved, audioFileURL: url)
                }
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            // Leave the file staged — it retries on the next foreground.
            log.error("transcribe of shared audio \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Diarize a freshly-imported shared transcript and persist a multi-speaker
    /// result on it (`diarizationJSON`, schema V9 → Speakers tab). Tolerant by
    /// contract: a busy transcriber/recorder or any diarize error is logged +
    /// breadcrumbed and leaves the transcript untouched — diarization is an
    /// ENHANCEMENT of the import, never a gate on it. The user can always run
    /// Detect speakers manually. See
    /// `docs/plans/speaker-notes-productization.md`.
    @MainActor
    private static func autoDiarize(_ transcript: Transcript, audioFileURL url: URL) async {
        // Snapshot before any await — the @Model is bound to `append`'s
        // short-lived context; don't read it across suspension points.
        let id = transcript.id
        let displayText = transcript.displayText

        // Load the diarizer (downloads the ~190 MB Nemotron 3 model on first use
        // if the Wi-Fi launch prefetch hasn't landed). Resident thereafter.
        await DiarizerHolder.shared.prepareIfNeeded()

        // Re-check RIGHT before diarizing. The drainer's entry guard is sampled
        // once, but a dictation can start mid-drain, and FluidAudio's shared
        // CoreML/BNNS state is unsafe under two concurrent inference graphs. If
        // the transcriber or recorder is busy now, SKIP this file (never wait,
        // never fail the import).
        guard !TranscriptionService.shared.isBusy, !RecordingService.shared.isRecording else {
            log.info("auto-diarize skipped for \(id, privacy: .public): transcriber/recorder busy")
            DiagnosticsLog.record(source: "main-app", category: .diarization, message: "Auto-diarize skipped: busy")
            return
        }

        do {
            let result = try await DiarizerHolder.shared.diarize(audioFileURL: url)
            if let rows = DiarizationLabeling.persistedRows(
                runs: result.runs,
                duration: result.duration,
                transcriptText: displayText
            ) {
                if let json = PersistedSpeakerRow.encode(rows) {
                    try TranscriptStore.updateDiarization(id: id, json: json)
                    log.info("auto-diarize persisted \(rows.count) turn(s) for \(id, privacy: .public)")
                    DiagnosticsLog.record(source: "main-app", category: .diarization, message: "Auto-diarize: \(rows.count) turns persisted")
                }
            } else {
                log.info("auto-diarize: single speaker for \(id, privacy: .public) — storing nothing")
                DiagnosticsLog.record(source: "main-app", category: .diarization, message: "Auto-diarize: single speaker")
            }
        } catch {
            log.error("auto-diarize failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            DiagnosticsLog.record(source: "main-app", category: .diarization, message: "Auto-diarize failed: \(error.localizedDescription)")
        }
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
