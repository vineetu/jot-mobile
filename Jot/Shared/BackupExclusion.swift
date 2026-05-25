import Foundation
import OSLog

/// Small util for setting `isExcludedFromBackup` on on-disk paths that
/// shouldn't be in the user's iCloud Device Backup.
///
/// Why this exists: by default, files under `Library/Application Support/`
/// ARE included in iOS Device Backup. We intentionally keep speech-model
/// weights there (not under `Library/Caches/`) because Application Support
/// is sticky — iOS doesn't evict it under memory pressure, so dictation
/// doesn't break unexpectedly. But the weights themselves are ~2 GB and
/// trivially re-downloadable, so they shouldn't bloat user backups.
///
/// Apple's `URLResourceValues.isExcludedFromBackup` is the public,
/// documented API for opting a path out of iCloud + iTunes backup
/// (per the iOS File System Programming Guide). The flag is sticky —
/// once set on a directory, it persists across reboots and is inherited
/// by files created within. Setting it again is a no-op.
enum BackupExclusion {
    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "backup-exclusion"
    )

    /// Sets `isExcludedFromBackup = true` on `~/Library/Application Support/FluidAudio/`.
    /// Covers the Parakeet 600M v2 weights (`parakeet-tdt-0.6b-v2-coreml/`)
    /// and any future downloaded variant that FluidAudio places under that
    /// parent directory. No-op if the directory doesn't exist (the user
    /// hasn't downloaded any variant yet); no-op if the flag is already set.
    ///
    /// Called per-launch from `JotApp.init` as a defensive measure — costs
    /// a few syscalls when the directory exists, costs nothing otherwise.
    /// Per-launch (rather than one-shot) so that a re-created directory
    /// (e.g. user deleted the variant from Settings then re-downloaded)
    /// still gets the flag set.
    static func excludeFluidAudioModels() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            log.error("Couldn't resolve applicationSupportDirectory")
            return
        }

        var fluidAudioDir = appSupport.appendingPathComponent("FluidAudio", isDirectory: true)

        guard FileManager.default.fileExists(atPath: fluidAudioDir.path) else {
            // No FluidAudio weights downloaded yet — nothing to exclude.
            // The flag will be set on a future launch after the user
            // downloads a variant.
            return
        }

        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try fluidAudioDir.setResourceValues(values)
            log.info("Set isExcludedFromBackup on \(fluidAudioDir.path, privacy: .public)")
        } catch {
            log.error(
                "Failed to set isExcludedFromBackup on FluidAudio dir: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
