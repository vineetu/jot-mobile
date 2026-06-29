import Foundation
import os

/// Temporary on-device store for the **source audio** of a transcript, kept so
/// the user can **re-transcribe** later — e.g. in another language after
/// downloading the multilingual model, or to redo a wrong-language detection
/// (`docs/multilingual-dictation`).
///
/// - **Format:** 16 kHz mono — exactly what Parakeet ingests — written as 16-bit
///   PCM WAV (~1.9 MB/min), the smallest faithful representation of what the
///   model sees. File-based captures (share / watch / file-import) are copied
///   as-is (any format round-trips through `transcribe(audioFileURL:)`).
/// - **Location:** App Group container `RetainedAudio/`, excluded from iCloud
///   backup (like the speech models).
/// - **Lifetime:** auto-purged after `retentionDays` (a launch sweep), and
///   deleted when its transcript is deleted.
/// - **Privacy:** 100% on-device; nothing is ever transmitted. Keyed by the
///   transcript's `id`.
///
/// Foundation-only so it stays compiled-into / safe-for every target (the
/// keyboard never calls it — it bounces recording to the app).
enum RetainedAudioStore {
    /// How long source audio is kept before the launch sweep deletes it.
    static let retentionDays = 3
    /// Parakeet's input rate. Mirrors `TranscriptionService.sampleRate`.
    private static let sampleRate = 16_000
    private static let log = Logger(subsystem: "com.vineetu.jot.mobile.Jot", category: "RetainedAudio")

    /// `…/AppGroup/RetainedAudio/`, created + backup-excluded on first use.
    static var directory: URL? {
        guard let base = AppGroup.containerURL else { return nil }
        let dir = base.appendingPathComponent("RetainedAudio", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            excludeFromBackup(dir)
        }
        return dir
    }

    /// Persist 16 kHz mono float samples as `<id>.wav`. Best-effort — a failure
    /// here must never affect the transcript that was just saved.
    static func save(samples: [Float], for id: UUID) {
        guard !samples.isEmpty, let dir = directory else { return }
        let url = dir.appendingPathComponent("\(id.uuidString).wav")
        do {
            try wavData(fromMonoFloat: samples).write(to: url, options: .atomic)
            excludeFromBackup(url)
        } catch {
            log.error("retain save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Persist by copying an existing audio file (share / watch / file-import),
    /// stored as `<id>.<ext>`. Best-effort.
    static func save(copyingFile src: URL, for id: UUID) {
        guard let dir = directory else { return }
        let ext = src.pathExtension.isEmpty ? "wav" : src.pathExtension
        let url = dir.appendingPathComponent("\(id.uuidString).\(ext)")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
            }
            try FileManager.default.copyItem(at: src, to: url)
            excludeFromBackup(url)
        } catch {
            log.error("retain copy failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Retained audio URL for a transcript, if present and not expired.
    static func url(for id: UUID) -> URL? {
        guard let dir = directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return nil }
        let prefix = id.uuidString + "."
        return entries.first { $0.lastPathComponent.hasPrefix(prefix) && !isExpired($0) }
    }

    /// `true` when a transcript still has retained, non-expired source audio
    /// (drives the "Re-transcribe" affordance visibility).
    static func hasAudio(for id: UUID) -> Bool { url(for: id) != nil }

    /// Delete the retained audio for one transcript (call on transcript delete).
    static func delete(for id: UUID) {
        guard let dir = directory,
              let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        let prefix = id.uuidString + "."
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Delete every retained file older than `retentionDays`. Run once at launch.
    @discardableResult
    static func purgeExpired() -> Int {
        guard let dir = directory,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return 0 }
        var purged = 0
        for url in entries where isExpired(url) {
            try? FileManager.default.removeItem(at: url)
            purged += 1
        }
        if purged > 0 {
            log.info("purged \(purged, privacy: .public) expired retained-audio file(s)")
        }
        return purged
    }

    private static func isExpired(_ url: URL) -> Bool {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        return Date().timeIntervalSince(modified) > Double(retentionDays) * 86_400
    }

    private static func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }

    // MARK: - WAV encoding (16-bit PCM, mono, 16 kHz)

    private static func wavData(fromMonoFloat samples: [Float]) -> Data {
        let bitsPerSample = 16, channels = 1
        let blockAlign = channels * bitsPerSample / 8
        let byteRate = sampleRate * blockAlign
        let dataSize = samples.count * blockAlign
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + dataSize)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1) /* PCM */; u16(UInt16(channels))
        u32(UInt32(sampleRate)); u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(dataSize))
        for s in samples {
            let clamped = max(-1.0, min(1.0, s))
            u16(UInt16(bitPattern: Int16(clamped * 32_767)))
        }
        return d
    }
}
