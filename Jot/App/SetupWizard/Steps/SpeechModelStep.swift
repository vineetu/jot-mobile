//
//  SpeechModelStep.swift
//  Jot
//
//  Phase 6 — wizard panel W3.
//  Purple "Parakeet" IconBox + "Download the speech model" + the existing
//  `transcriptionService.warmUp()` path gated through `ModelDownloadGate`.
//  Bundle includes Parakeet (speech) + streaming EOU + CTC vocab models.
//
//  ## Already-installed detection (re-run wizard path)
//
//  When the user re-runs the wizard via Settings → About → "Re-run setup
//  wizard", Parakeet's weights are already on disk. The transcription
//  service's `modelState` starts at `.notLoaded` until `warmUp()` is called,
//  so without an explicit on-disk probe the user would see the "Download ·
//  1.25 GB" CTA again — tapping it would warmUp() and return instantly
//  (because the files are already there), which is confusing chrome that
//  implies a download happened when none did. `.onAppear` probes
//  `TranscriptionService.modelsExistOnDiskForSelectedVariant()` and pivots
//  the panel into an "installed" affordance — a "Speech model installed"
//  pill + a normal Continue button — so the re-run path stays explicit
//  without spinning a fake download.
//
//  ## Two source-of-truth signals (do not conflate)
//
//  - `modelAlreadyOnDisk` — SOURCE OF TRUTH for "wizard can skip download."
//    AND-gates all three bundle probes (Parakeet weights + streaming EOU +
//    CTC vocab). Resolved once on `.onAppear`. The "installed → Continue"
//    affordance MUST gate on this flag, not on `modelState`.
//  - `transcriptionService.modelState == .ready` — only confirms Parakeet
//    has been warmed into ANE for actual recording. `JotApp.task` calls
//    `warmUp()` at launch when setup is complete, so `.ready` can flip true
//    even if CTC vocab was wiped out-of-band (theoretical partial-wipe).
//    Using `.ready` to drive the "installed" UI would let the user skip a
//    refetch they actually need.
//
//  ## Four UI states this panel can render
//
//  1. On-disk + warmed (re-run wizard): `modelAlreadyOnDisk == true` →
//     "Speech model installed" + plain "Continue". No download, no
//     preparing spinner.
//  2. Cold-start (no model on disk): `.notLoaded` → "Download · 1.25 GB"
//     → `.downloading(fraction)` linear progress → `.loading` "Just a
//     moment" spinner (warm into ANE for Parakeet TDT) → `.ready`
//     auto-advances to W4. The `.loading` state matters
//     because without it the panel jumps from 100% download straight to
//     a quiet Continue button while ANE warm is still running — the user
//     either taps Continue too early (W7 shows "Speech model isn't
//     ready") or sits silent without feedback.
//  3. Partial-wipe (Parakeet on disk but EOU or CTC missing):
//     `modelAlreadyOnDisk == false` AND `modelState == .ready` →
//     "Download · 1.25 GB" CTA (refetches the missing bundle; the
//     already-on-disk bundles no-op via `force: false`).
//  4. Download failure: `.failed(reason)` → "Retry · 1.25 GB" with the
//     reason in the body. Also the safety net if ANE warm throws during
//     state 2 — `ensurePreparing()` lands in `.failed` and the user gets
//     a retry CTA instead of being stuck on "Preparing…" forever.
//

import SwiftUI

struct SpeechModelStep: View {
    let onClose: () -> Void
    let onAdvance: () -> Void

    @Environment(TranscriptionService.self) private var transcriptionService
    @Environment(StreamingTranscriptionService.self) private var streamingService
    @Bindable var gate: ModelDownloadGate

    /// Resolved once on appear. Stays true for the lifetime of this panel
    /// so the "installed" affordance doesn't flip back to the download CTA
    /// if `modelState` briefly transitions through `.loading` while a
    /// background warm-up runs. Probed off `TranscriptionService` so the
    /// check matches the source of truth used by `JotApp.task`.
    @State private var modelAlreadyOnDisk: Bool = false

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .core(current: 2), onClose: onClose)
        ) {
            VStack(spacing: 24) {
                Spacer(minLength: 50)

                parakeetTile
                    .padding(.bottom, 4)

                WizardTitle(text: titleText)

                WizardBody(text: bodyText)

                progressAccessory

                Spacer(minLength: 12)
            }
        } footer: {
            WizardPrimaryButton(
                title: primaryTitle,
                subtitle: primarySubtitle,
                isDisabled: primaryDisabled,
                action: primaryAction
            )
        }
        .onAppear {
            gate.start()
            // Detect the re-run-wizard path where all three bundles
            // (Parakeet weights, streaming EOU, CTC vocab) are already on
            // disk from a prior setup pass. Without this probe the panel
            // would render the "Download · 1.25 GB" CTA against
            // `modelState == .notLoaded` even though `warmUp()` would
            // return instantly. AND-ing all three guards against partial
            // wipes — if any one bundle is missing we fall back to the
            // download CTA so the cold-download path can refetch it.
            modelAlreadyOnDisk = TranscriptionService.modelsExistOnDiskForSelectedVariant()
                && StreamingTranscriptionService.modelsExistOnDisk()
                && CtcModelCache.shared.isCached
        }
        .onChange(of: transcriptionService.modelState) { _, new in
            // Auto-advance on .ready so the user doesn't sit on a finished
            // download with a passive Continue tap. Matches W2's auto-advance
            // pattern after mic permission is granted. Suppressed on the
            // re-run-wizard path so the user sees explicit "installed"
            // confirmation rather than a flash-through.
            if case .ready = new, !modelAlreadyOnDisk { onAdvance() }
        }
    }

    // MARK: - Tile

    private var parakeetTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.345, green: 0.337, blue: 0.839),
                            Color(red: 0.247, green: 0.239, blue: 0.667)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                .blendMode(.plusLighter)
            Image(systemName: "diamond.fill")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 92)
        .shadow(
            color: Color(red: 0.345, green: 0.337, blue: 0.839).opacity(0.35),
            radius: 15,
            x: 0,
            y: 10
        )
        .accessibilityHidden(true)
    }

    // MARK: - Copy

    private var titleText: String {
        if modelAlreadyOnDisk { return "Speech model installed" }
        switch transcriptionService.modelState {
        // `.ready` without `modelAlreadyOnDisk` means Parakeet is warmed
        // into ANE but an auxiliary bundle (EOU or CTC) is missing — fall
        // through to the download CTA so the cold-path refetches it.
        case .ready: return "Download the speech model"
        case .failed: return "Download failed"
        // `.loading` here is the post-download warm into ANE — `ensurePreparing()`
        // chains .downloading → .loading → .ready inside a single async pass,
        // so this state is hit naturally after the 100% mark.
        case .loading: return "Preparing model…"
        case .downloading: return "Downloading Parakeet"
        case .notLoaded: return "Download the speech model"
        }
    }

    private var bodyText: String {
        if modelAlreadyOnDisk {
            return "Parakeet is already on this iPhone — about 1.25 GB."
        }
        switch transcriptionService.modelState {
        // `.ready` here means Parakeet warmed but an aux bundle is missing
        // — mirror the `.notLoaded` copy so the download CTA reads cleanly.
        case .ready:
            return "Parakeet runs on your iPhone — about 1.25 GB. English only for now."
        case .failed(let reason):
            return reason
        case .loading:
            // Honest copy: we don't observe ANE warm progress, and device-
            // class variance (A16 vs A18 Pro, thermal state, etc.) makes
            // any specific estimate fragile. The user just needs to know
            // the wizard hasn't stalled.
            return "Loading into the Neural Engine. Just a moment."
        case .downloading:
            return "Keep Jot open while the download finishes."
        case .notLoaded:
            return "Parakeet runs on your iPhone — about 1.25 GB. English only for now."
        }
    }

    private var primaryTitle: String {
        if modelAlreadyOnDisk { return "Continue" }
        switch transcriptionService.modelState {
        // `.ready` without on-disk truth means an aux bundle is missing —
        // surface the download CTA so the user kicks off a refetch.
        case .ready: return "Download · 1.25 GB"
        case .failed: return "Retry · 1.25 GB"
        case .notLoaded: return "Download · 1.25 GB"
        case .downloading(let f):
            return "Downloading… \(Int((f * 100).rounded()))%"
        case .loading: return "Preparing…"
        }
    }

    private var primarySubtitle: String? {
        if modelAlreadyOnDisk { return nil }
        switch transcriptionService.modelState {
        // `.ready` here is the aux-bundle-missing path — show the same
        // "Wi-Fi recommended" hint as the cold-download path.
        case .notLoaded, .failed, .ready:
            return "Wi-Fi recommended"
        default:
            return nil
        }
    }

    private var primaryAction: () -> Void {
        if modelAlreadyOnDisk { return onAdvance }
        switch transcriptionService.modelState {
        // `.ready` without `modelAlreadyOnDisk` is the partial-wipe path:
        // tapping must kick a refetch (which will no-op on bundles already
        // on disk and pull the missing one), not advance into a broken
        // recording flow.
        case .ready: return startDownload
        case .notLoaded, .failed: return startDownload
        case .downloading, .loading: return {}
        }
    }

    private var primaryDisabled: Bool {
        if modelAlreadyOnDisk { return false }
        switch transcriptionService.modelState {
        case .downloading, .loading: return true
        // `.ready` here routes to `startDownload` (see `primaryAction`), so
        // it must respect the network gate just like the cold-download path.
        case .ready: return !gate.canStartDownload
        case .notLoaded, .failed: return !gate.canStartDownload
        }
    }

    // MARK: - Progress / gate row

    @ViewBuilder
    private var progressAccessory: some View {
        // Re-run path: weights are on disk, so hide the gate / progress
        // chrome entirely. Rendering the network-gate row here would
        // dangle a "Wi-Fi" + "Allow cellular" toggle below an "installed"
        // pill which is incongruous.
        if modelAlreadyOnDisk {
            EmptyView()
        } else {
            progressAccessoryByState
        }
    }

    @ViewBuilder
    private var progressAccessoryByState: some View {
        switch transcriptionService.modelState {
        case .downloading(let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(Color.jotAccent)
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Color.jotMute)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)

        case .loading:
            // Slightly shrunk spinner to sit comfortably below the title /
            // body copy without dominating the panel — matches the visual
            // weight of the linear progress bar in the `.downloading` branch.
            ProgressView()
                .scaleEffect(0.9)
                .padding(.top, 4)

        // `.ready` reaches here only when `modelAlreadyOnDisk == false`
        // (the outer guard hides this view otherwise). That's the aux-
        // bundle-missing path, so show the same network gate row as the
        // cold-download path — the user will kick a refetch via the CTA.
        case .notLoaded, .failed, .ready:
            gateRow
        }
    }

    @ViewBuilder
    private var gateRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: networkIcon)
                    .foregroundStyle(Color.jotMute)
                Text("On \(gate.networkType.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(Color.jotMute)
                Spacer(minLength: 0)
                Text("~1.25 GB")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.jotInk)
            }

            Toggle(isOn: $gate.allowCellular) {
                Text("Allow cellular")
                    .font(.subheadline)
                    .foregroundStyle(Color.jotInk)
            }
            .tint(Color.jotAccent)

            if !gate.canStartDownload {
                Text(gateBlockedReason)
                    .font(.caption)
                    .foregroundStyle(Color.jotWarningInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var networkIcon: String {
        switch gate.networkType {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wired: return "cable.connector"
        case .other: return "network"
        case .unavailable: return "wifi.slash"
        }
    }

    private var gateBlockedReason: String {
        switch gate.networkType {
        case .cellular: return "Turn on \"Allow cellular\" to download over cellular."
        case .unavailable: return "Connect to the internet to download."
        case .wifi, .wired, .other: return ""
        }
    }

    // MARK: - Download kickoff

    private func startDownload() {
        // Same bundle the original wizard kicks off — Parakeet + streaming
        // EOU + CTC. All three are gated under this single consent tap so
        // the user sees one progress bar for the combined ~1.25 GB.
        transcriptionService.warmUp()
        streamingService.warmUp()
        Task.detached {
            _ = try? await CtcModelCache.shared.ensureLoaded()
        }
    }
}
