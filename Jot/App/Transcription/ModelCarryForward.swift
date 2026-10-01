import FluidAudio
import Foundation
import os.log

/// **Generalized carry-forward engine** — the safe first step toward stripping
/// the two bundled ML models (Parakeet 600M v2 and the CTC 110M vocabulary
/// scorer) from the app binary.
///
/// See `docs/plans/model-externalization-sub-50mb.md`. This is the §A1
/// generalization of the proven, adversarially-reviewed
/// `V2CarryForwardMigration` §A machinery
/// (`docs/dictation-engine-rework/v2-carry-forward-migration-design.md`): copy
/// the bundled model into the exact private directory a *future* stripped
/// build's loader falls through to, so the eventual bundle strip (Build B) is a
/// pure data move with zero re-download for existing users.
///
/// The hard part — recursive file-count+size **signature** verify, copy-to-
/// temp-sibling + **atomic rename** install, abandoned-temp sweep, **free-space
/// preflight**, per-launch idempotent no-op re-check, **iCloud backup
/// exclusion**, and DiagnosticsLog breadcrumbs — lives once in `carry(...)` and
/// is driven for both assets serially from one detached launch task.
///
/// This build still **bundles** both — it is NOT the strip (Build B). It
/// only makes the future strip safe. `V2CarryForwardMigration` retains the
/// separate §D existing-vs-new-user English-engine-default resolution.
enum ModelCarryForward {

    private static let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot",
        category: "model-carry-forward"
    )

    // MARK: - Per-asset free-space preflights

    /// Transient footprint is the temp copy alongside the still-present bundle.
    /// v2 keeps its proven ~900 MB headroom; CTC (~99 MB) needs ~250 MB,
    /// including the temp sibling.
    private static let v2RequiredFreeBytes: Int64 = 900 * 1024 * 1024
    private static let ctcRequiredFreeBytes: Int64 = 250 * 1024 * 1024

    // MARK: - Launch entry point

    /// Idempotent per-launch carry-forward for BOTH assets, serially, off
    /// the main thread, best-effort, self-healing. One detached `.utility` task
    /// drives them one after another — a cheap presence+verify check each
    /// launch, a no-op once each copy is complete (§A "no stuck-flag"). Serial
    /// (not concurrent) so two big `copyItem`s don't thrash the filesystem or
    /// spike transient disk use all at once.
    static func runAllIfNeeded() {
        Task.detached(priority: .utility) {
            carryV2IfNeeded()
            carryCTCIfNeeded()
        }
    }

    // MARK: - Per-asset drivers (gates differ; the engine is shared)

    private static func carryV2IfNeeded() {
        // Gate 1 — only on devices that can actually run Parakeet (iPhone 14
        // Pro+/iPad M1+). A sub-tier device is Apple-only for English, so
        // copying ~443 MB it will never load is pure waste.
        guard TranscriptionService.parakeetUsable else { return }
        // Gate 2 — only while v2 is still bundled (after the strip
        // `bundled600mDirectory()` is nil and there's nothing to carry).
        guard let bundleLeaf = TranscriptionService.bundled600mDirectory() else { return }

        carry(
            bundleLeaf: bundleLeaf,
            to: MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetV2),
            requiredFreeBytes: v2RequiredFreeBytes,
            label: "v2"
        )
    }

    private static func carryCTCIfNeeded() {
        // CTC copies on EVERY device — vocabulary boosting works on all
        // hardware, unlike Parakeet dictation. Gate only on the bundle still
        // shipping the scorer.
        let bundleLeaf = Bundle.main.bundleURL
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Parakeet", isDirectory: true)
            .appendingPathComponent(CtcModelVariant.ctc110m.repo.folderName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundleLeaf.path) else { return }

        // Destination MUST equal the loader/download target
        // (`CtcModels.defaultCacheDirectory` /
        // `defaultModelsDirectory(for: .parakeetCtc110m)`) — folder name
        // `parakeet-ctc-110m-coreml` WITH `-coreml`, unlike the v2 leaf.
        carry(
            bundleLeaf: bundleLeaf,
            to: MLModelConfigurationUtils.defaultModelsDirectory(for: .parakeetCtc110m),
            requiredFreeBytes: ctcRequiredFreeBytes,
            label: "ctc-110m"
        )
    }


    // MARK: - §A — the generic carry-forward engine

    /// Copy `bundleLeaf` into `dest` via temp-sibling + verify + atomic rename,
    /// with a free-space preflight and iCloud backup exclusion. Idempotent: a
    /// no-op once a complete, signature-matching copy already exists at `dest`.
    /// `dest`'s leaf name need NOT match `bundleLeaf`'s — the completeness
    /// yardstick is the recursive (file-count, total-size) signature, which is
    /// rename-agnostic.
    private static func carry(
        bundleLeaf: URL,
        to dest: URL,
        requiredFreeBytes: Int64,
        label: String
    ) {
        let fm = FileManager.default
        let parent = dest.deletingLastPathComponent()

        // Compute the bundle's signature once (recursive file-count + total
        // size). This is the yardstick for BOTH the "already done?" check and
        // the post-copy verify — STRONGER than a `modelsExist`-style top-level
        // dir stat, which cannot detect a truncated copy.
        guard let bundleSig = signature(of: bundleLeaf) else {
            log.error("Carry-forward[\(label, privacy: .public)]: could not read bundle signature at \(bundleLeaf.path, privacy: .public)")
            return
        }

        // Already carried-forward and complete? Cheap no-op forever after.
        if fm.fileExists(atPath: dest.path) {
            if let destSig = signature(of: dest), destSig == bundleSig {
                return
            }
            // A partial/mismatched copy (interrupted earlier run, corrupt, or a
            // shape change). Fall through — we rebuild via a fresh temp + atomic
            // swap below; the stale leaf is removed only in the final atomic
            // install so the bundle keeps serving until then.
            log.notice("Carry-forward[\(label, privacy: .public)]: destination present but incomplete/mismatched; rebuilding")
        }

        // Free-space preflight — skip cleanly + retry next launch if short.
        // Harmless in Build A: the bundle still serves.
        if let free = availableImportantCapacity(at: parent), free < requiredFreeBytes {
            log.notice(
                "Carry-forward[\(label, privacy: .public)]: skipped — low free space (\(free, privacy: .public) < \(requiredFreeBytes, privacy: .public) bytes); retry next launch"
            )
            return
        }

        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            log.error("Carry-forward[\(label, privacy: .public)]: could not create parent \(parent.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        // Sweep any abandoned temp siblings from an interrupted prior run before
        // starting a fresh one (crash-mid-copy leaves only a temp, never a
        // half-model in the leaf).
        sweepTempSiblings(in: parent, destLeaf: dest.lastPathComponent)

        // Copy into a TEMP sibling, verify, then atomically install. Never copy
        // in place. `copyItem` on the whole leaf brings the entire package tree
        // across in one shot; the temp's leaf is our own name, so this handles
        // any future leaf-rename for free.
        let temp = parent.appendingPathComponent(
            "\(dest.lastPathComponent).carry-tmp-\(UUID().uuidString)",
            isDirectory: true
        )

        let startedAt = Date()
        do {
            try fm.copyItem(at: bundleLeaf, to: temp)
        } catch {
            log.error("Carry-forward[\(label, privacy: .public)]: copy to temp failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: temp)
            return
        }

        // Verify the temp is byte-count/file-count complete vs the bundle. A
        // truncated copy is caught here and discarded, never installed.
        guard let tempSig = signature(of: temp), tempSig == bundleSig else {
            log.error("Carry-forward[\(label, privacy: .public)]: temp copy failed verification; discarding")
            try? fm.removeItem(at: temp)
            return
        }

        // Atomic install: remove any stale (incomplete) leaf, then rename the
        // verified temp into place. `moveItem` on the same volume is an atomic
        // rename; the only window is "leaf briefly absent" (safe — the bundle
        // still serves in Build A), never "half-model in the leaf".
        do {
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.moveItem(at: temp, to: dest)
        } catch {
            log.error("Carry-forward[\(label, privacy: .public)]: atomic install failed: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: temp)
            return
        }

        // Backup-exclude the carried weights the moment they land, so a
        // multi-hundred-MB model doesn't bloat iCloud backups. The per-launch
        // sweeps (FluidAudio for v2/CTC) also
        // cover this, but exclude explicitly now so the copy is excluded from
        // the moment it lands, not only after the next launch (⚠️REVIEW-2 — the
        // v2 fix that established install-time exclusion is load-bearing).
        let excluded = BackupExclusion.setExcludedFromBackupRecursively(at: dest)

        let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
        DiagnosticsLog.record(
            source: "main-app",
            category: .modelLoad,
            message: "carried \(label) forward to App Support",
            metadata: [
                "files": "\(bundleSig.fileCount)",
                "bytes": "\(bundleSig.totalSize)",
                "copyMS": "\(elapsedMS)",
                "excluded": "\(excluded)",
                "kind": "carry-forward",
            ]
        )
        log.info(
            "Carry-forward[\(label, privacy: .public)]: installed \(bundleSig.fileCount, privacy: .public) files (\(bundleSig.totalSize, privacy: .public) bytes) at \(dest.path, privacy: .public) in \(elapsedMS, privacy: .public)ms"
        )
    }

    // MARK: - Helpers (moved verbatim from V2CarryForwardMigration §A)

    /// Recursive (file-count, total-logical-size) of a directory tree, counting
    /// only regular files. This is the completeness yardstick used to detect a
    /// truncated/partial copy that a dir-existence check would miss.
    private static func signature(of dir: URL) -> (fileCount: Int, totalSize: Int64)? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return nil
        }
        var count = 0
        var size: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            count += 1
            size += Int64(values.fileSize ?? 0)
        }
        return (count, size)
    }

    /// Available important-usage capacity on the volume backing `url`, or `nil`
    /// if it can't be read (in which case we proceed rather than block on an
    /// unreadable metric).
    private static func availableImportantCapacity(at url: URL) -> Int64? {
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path) {
            let parent = probe.deletingLastPathComponent()
            if parent == probe { break }
            probe = parent
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Remove abandoned `<destLeaf>.carry-tmp-*` temp dirs left by an
    /// interrupted copy (crash/jetsam mid-`copyItem`).
    private static func sweepTempSiblings(in parent: URL, destLeaf: String) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            return
        }
        let prefix = "\(destLeaf).carry-tmp-"
        for url in entries where url.lastPathComponent.hasPrefix(prefix) {
            try? fm.removeItem(at: url)
        }
    }
}
