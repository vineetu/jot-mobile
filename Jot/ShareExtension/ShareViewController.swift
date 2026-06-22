import os
import UIKit
import UniformTypeIdentifiers

/// Principal class for the "Send to Jot" Share Extension.
///
/// Receives audio shared from any app (Voice Memos, Files, Mail…), copies the
/// BYTES of each shared item into the App Group's `PendingShares/` queue, shows
/// a brief "Saved to Jot ✓" confirmation, and completes — **without opening
/// Jot** (Model B, locked in `docs/share-audio-to-jot/design.md`: never
/// navigate the user away; the main app drains + transcribes the queue the next
/// time it naturally foregrounds, via `PendingShareDrainer`).
///
/// ## Why bytes, not the URL
/// `loadFileRepresentation` hands back a temp URL inside THIS extension's
/// sandbox that iOS reclaims the instant the completion returns — the main app
/// (a different sandbox) could never read it (the cross-sandbox
/// `.audioFileUnreadable` trap documented in `TranscribeAudioFileIntent`). The
/// App Group container is shared by both processes, so copying the bytes there
/// is the durable handoff.
///
/// ## Audio-only
/// The `NSExtensionActivationRule` (Info.plist) already keeps Jot out of the
/// share sheet for non-audio, so this should only ever see audio. The
/// per-attachment `hasItemConformingToTypeIdentifier(UTType.audio)` check is the
/// belt-and-suspenders fallback: a mis-tagged item yields the friendly
/// "Jot can only transcribe audio files." message, never a crash.
final class ShareViewController: UIViewController {
    private let log = Logger(
        subsystem: "com.vineetu.jot.mobile.Jot.ShareExtension",
        category: "Share"
    )

    private let card = UIView()
    private let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        buildConfirmationCard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await processSharedItems() }
    }

    // MARK: - Staging

    private func processSharedItems() async {
        guard let dir = AppGroup.pendingSharesDirectory() else {
            log.error("App Group container unavailable — entitlement misconfigured")
            await finish(message: "Couldn't save to Jot. Try again.", success: false)
            return
        }

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let attachments = items.flatMap { $0.attachments ?? [] }
        let audioAttachments = attachments.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
        }

        guard !audioAttachments.isEmpty else {
            await finish(message: "Jot can only transcribe audio files.", success: false)
            return
        }

        var saved = 0
        for provider in audioAttachments {
            if await stage(provider, into: dir) { saved += 1 }
        }

        guard saved > 0 else {
            await finish(message: "Jot can only transcribe audio files.", success: false)
            return
        }

        let message = saved == 1 ? "Saved to Jot ✓" : "Saved \(saved) to Jot ✓"
        await finish(message: message, success: true)
    }

    /// Copy one shared audio item's bytes into `<dir>/<uuid>.<ext>`. Returns
    /// `false` (and logs) on any load/copy failure so one bad item can't sink
    /// the rest of a multi-select share.
    private func stage(_ provider: NSItemProvider, into dir: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.audio.identifier) { [weak self] url, error in
                guard let self else { continuation.resume(returning: false); return }
                if let error {
                    self.log.error("loadFileRepresentation failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                    return
                }
                guard let url else { continuation.resume(returning: false); return }
                // Preserve the real audio extension (m4a/mp3/wav/caf…) so the
                // main app's AVAudioFile read picks the right format.
                let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
                let dest = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
                do {
                    // Copy the file directly rather than `Data(contentsOf:)` —
                    // a long memo can be tens of MB and a share extension's
                    // memory budget is tight, so stream the copy instead of
                    // pulling the whole file into our address space. `url` is a
                    // local temp iOS handed us (not security-scoped), valid for
                    // the life of this completion, so a synchronous copy is safe.
                    try FileManager.default.copyItem(at: url, to: dest)
                    self.log.info("staged shared audio \(dest.lastPathComponent, privacy: .public)")
                    continuation.resume(returning: true)
                } catch {
                    self.log.error("stage copy failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    // MARK: - Confirmation UI

    private func buildConfirmationCard() {
        card.backgroundColor = .secondarySystemBackground
        card.layer.cornerRadius = 18
        card.alpha = 0
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        label.text = "Saving…"
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .label
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(label)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 40),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -40),
            label.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            label.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
            label.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
        ])
        UIView.animate(withDuration: 0.2) { self.card.alpha = 1 }
    }

    /// Show the final message briefly, then complete the request. We never call
    /// `extensionContext.open` — Model B leaves the user exactly where they are.
    @MainActor
    private func finish(message: String, success: Bool) async {
        label.text = message
        try? await Task.sleep(nanoseconds: success ? 750_000_000 : 1_200_000_000)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
