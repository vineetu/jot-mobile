import FluidAudio
import Foundation

/// Deletes what retired features left on the phone. Idempotent and best-effort:
/// missing files and keys are no-ops, so after the first launch it costs a few
/// failed stats. Called once per launch at the tail of the warm chain.
///
/// - pyannote/VBx diarizer models + the owner voiceprint — replaced by Nemotron 3
///   Diarization (2026-09-27; no voice fingerprint).
/// - The TTS Lab (text-to-speech, voice cloning) — removed 2026-09-27 (owner):
///   its downloaded voice models, cloned voices, and their registry + consent log.
/// - Parakeet v3 (~461 MB) — replaced by Parakeet Ultra for the European
///   languages on 2026-09-27; nothing loads v3 any more.
enum RetiredFeatureCleanup {
    static func run() {
        let fm = FileManager.default
        // Only ever name a retired model's OWN repo folder. NOT
        // `OfflineDiarizerModels.defaultModelsDirectory()` — that is the shared
        // `FluidAudio/Models/` root, and deleting it on every launch wiped the
        // live dictation models (Unified English, punctuation, vocabulary CTC,
        // Nemotron, Ultra), forcing a slow reload/re-download after each relaunch.
        var urls = [
            MLModelConfigurationUtils.defaultModelsDirectory(for: .diarizer),
        ]
        // v3 stays until Ultra has landed — it is the European fallback
        // (`TranscriptionService.europeanFallsBackToV3`).
        if !TranscriptionService.europeanFallsBackToV3 {
            urls.append(MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV3))
        }
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: false) {
            urls.append(appSupport.appendingPathComponent("TTSVoices", isDirectory: true))
            // FluidAudio's TTS store on iOS is `Application Support/fluidaudio/Models/`
            // (`TtsCacheDirectory`). Name only the TTS repo folders — never the
            // root, which may resolve to the dictation models' `FluidAudio/`.
            let tts = appSupport.appendingPathComponent("fluidaudio/Models", isDirectory: true)
            for repo in [Repo.supertonic3, Repo.pocketTts] {
                urls.append(tts.appendingPathComponent(repo.folderName, isDirectory: true))
            }
        }
        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false) {
            // Older TTS builds cached here; dictation models never live in Caches.
            urls.append(caches.appendingPathComponent("fluidaudio/Models", isDirectory: true))
        }
        for url in urls where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        // The voiceprint lived in the App Group store (`OwnerVoiceprintStore`);
        // clear the standard store too in case an older build wrote it there.
        AppGroup.defaults.removeObject(forKey: "jot.diarization.ownerVoiceprint")
        UserDefaults.standard.removeObject(forKey: "jot.diarization.ownerVoiceprint")
        for key in ["jot.tts.clonedVoices", "jot.tts.voiceCloneConsentRecords"] {
            AppGroup.defaults.removeObject(forKey: key)
        }
    }
}
