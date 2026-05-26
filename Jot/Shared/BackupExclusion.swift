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

    /// Sets `isExcludedFromBackup = true` on `~/Library/Application Support/FluidAudio/`
    /// AND on every file + subdirectory inside it.
    ///
    /// **Why recursive.** Apple documents the flag as "extending to items
    /// the directory contains," but empirically files that existed
    /// **before** the flag was set on the parent can still end up in iOS
    /// Device Backup. Setting the flag on each file individually is the
    /// only way to guarantee a clean backup for users whose FluidAudio
    /// directory predates the launch where the parent flag was applied.
    /// Hit this bug in 1.0.2 (8+): users reported ~2 GB backups even
    /// though the parent flag had been set. Recursive flag pass fixes it.
    ///
    /// Covers the Parakeet 600M v2 weights (`parakeet-tdt-0.6b-v2-coreml/`)
    /// and any future downloaded variant that FluidAudio places under
    /// that parent. No-op if the directory doesn't exist yet.
    ///
    /// Called per-launch from `JotApp.init`. The recursive walk is bounded
    /// (FluidAudio contains tens of files, not millions), so launch cost
    /// is negligible. Per-launch (rather than one-shot) so that a
    /// re-created directory or a newly-downloaded variant still gets the
    /// flag applied to every file.
    static func excludeFluidAudioModels() {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            log.error("Couldn't resolve applicationSupportDirectory")
            return
        }

        let fluidAudioDir = appSupport.appendingPathComponent("FluidAudio", isDirectory: true)

        guard FileManager.default.fileExists(atPath: fluidAudioDir.path) else {
            return
        }

        let count = setExcludedFromBackupRecursively(at: fluidAudioDir)
        log.info("Set isExcludedFromBackup on \(count, privacy: .public) item(s) under \(fluidAudioDir.path, privacy: .public)")
    }

    /// Walk the tree rooted at `url`, set `isExcludedFromBackup = true`
    /// on the root + every descendant file/dir. Returns the number of
    /// items successfully flagged. Errors on individual items are logged
    /// + skipped (don't bail mid-walk; one stuck file shouldn't leave the
    /// rest of the tree backed up).
    @discardableResult
    static func setExcludedFromBackupRecursively(at url: URL) -> Int {
        var flagged = 0
        if setExcluded(on: url) { flagged += 1 }

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { failedURL, error in
                Self.log.error("Backup walk error at \(failedURL.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return true
            }
        ) else { return flagged }

        for case let fileURL as URL in enumerator {
            if setExcluded(on: fileURL) { flagged += 1 }
        }
        return flagged
    }

    /// Sets `isExcludedFromBackup = true` on a single URL.
    /// Takes URL by value (not inout) because `os.log` interpolation
    /// is an autoclosure that can't capture inout parameters.
    private static func setExcluded(on url: URL) -> Bool {
        var mutableURL = url
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try mutableURL.setResourceValues(values)
            return true
        } catch {
            let pathString = url.path
            log.error(
                "Failed to set isExcludedFromBackup on \(pathString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    /// Diagnostic snapshot of the FluidAudio directory: total disk usage
    /// and how many of its items are flagged `isExcludedFromBackup`.
    /// Surfaced in Settings → About so the user can confirm the backup
    /// exclusion landed without us having to ask them to read Console.
    struct FluidAudioReport: Sendable {
        let exists: Bool
        let totalBytes: Int64
        let totalItems: Int
        let excludedItems: Int
        var totalMegabytes: Double { Double(totalBytes) / (1024 * 1024) }
        var allExcluded: Bool { exists ? excludedItems == totalItems && totalItems > 0 : true }
    }

    static func fluidAudioReport() -> FluidAudioReport {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            return FluidAudioReport(exists: false, totalBytes: 0, totalItems: 0, excludedItems: 0)
        }
        let dir = appSupport.appendingPathComponent("FluidAudio", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            return FluidAudioReport(exists: false, totalBytes: 0, totalItems: 0, excludedItems: 0)
        }

        var bytes: Int64 = 0
        var total = 0
        var excluded = 0

        let keys: [URLResourceKey] = [.fileSizeKey, .isExcludedFromBackupKey, .isDirectoryKey]
        let fm = FileManager.default

        // Root counts as one item.
        total += 1
        if let v = try? dir.resourceValues(forKeys: Set(keys)), v.isExcludedFromBackup == true {
            excluded += 1
        }

        if let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: keys) {
            for case let url as URL in enumerator {
                total += 1
                if let v = try? url.resourceValues(forKeys: Set(keys)) {
                    if v.isExcludedFromBackup == true { excluded += 1 }
                    if v.isDirectory != true, let size = v.fileSize {
                        bytes += Int64(size)
                    }
                }
            }
        }

        return FluidAudioReport(
            exists: true,
            totalBytes: bytes,
            totalItems: total,
            excludedItems: excluded
        )
    }
}
