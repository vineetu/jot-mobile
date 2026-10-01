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
        var urls = [
            OfflineDiarizerModels.defaultModelsDirectory(),
            MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV3),
        ]
        if let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: false) {
            urls.append(appSupport.appendingPathComponent("TTSVoices", isDirectory: true))
        }
        if let caches = try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: false) {
            // TTS-only model cache (Supertonic + PocketTTS); dictation models
            // live under Application Support, not here.
            urls.append(caches.appendingPathComponent("fluidaudio/Models", isDirectory: true))
        }
        for url in urls where fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: url)
        }
        UserDefaults.standard.removeObject(forKey: "jot.diarization.ownerVoiceprint")
        for key in ["jot.tts.clonedVoices", "jot.tts.voiceCloneConsentRecords"] {
            AppGroup.defaults.removeObject(forKey: key)
        }
    }
}
