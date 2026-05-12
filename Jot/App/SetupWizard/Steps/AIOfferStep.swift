//
//  AIOfferStep.swift
//  Jot
//
//  Phase 6 — wizard panel W11 (optional).
//  Coral sparkle IconBox + "Add AI rewrite" + "Download · 2.4 GB" CTA.
//  Wires to `LLMClientUIAdapter.warm()` against
//  `LLMClientFactory.shared.client()`. After the warm is kicked off we
//  dismiss the wizard — the existing in-app `AIRewriteDownloadBanner`
//  surfaces continuing progress.
//

import SwiftUI

struct AIOfferStep: View {
    let onClose: () -> Void
    let onComplete: () -> Void

    @State private var didKickOff = false

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .optional(current: 1), onClose: onClose)
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 40)

                sparkleTile
                    .padding(.bottom, 4)

                WizardTitle(text: "Add AI rewrite")

                WizardBody(text: bodyCopy)

                Spacer(minLength: 16)
            }
        } footer: {
            WizardPrimaryButton(
                title: "Download · \(JotDesign.activeRewriteModelSize)",
                isDisabled: didKickOff,
                action: kickOffWarm
            )
            WizardSecondaryTextButton(title: "Skip", action: onComplete)
        }
    }

    private var bodyCopy: String {
        "Polish dictations and convert prose to bullets. \(JotDesign.activeRewriteModelDisplayName) runs on your iPhone — about \(JotDesign.activeRewriteModelSize)."
    }

    // MARK: - Tile

    private var sparkleTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 1.00, green: 0.32, blue: 0.28),
                            Color(red: 0.90, green: 0.23, blue: 0.19)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .inset(by: 0.5)
                .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                .blendMode(.plusLighter)
            Image(systemName: "sparkles")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 92, height: 92)
        .shadow(
            color: Color(red: 1.00, green: 0.23, blue: 0.19).opacity(0.35),
            radius: 15,
            x: 0,
            y: 10
        )
        .accessibilityHidden(true)
    }

    // MARK: - Warm kickoff

    private func kickOffWarm() {
        guard !didKickOff else { return }
        didKickOff = true

        // Kick off Phi-4 (or whichever client the factory returns) via the
        // UI adapter so its `observableStatus` mirror is alive when the
        // user lands on the AI Rewrite settings row. The download itself
        // is long-running (~2.4 GB) and we deliberately don't block the
        // wizard on it — the existing `AIRewriteDownloadBanner` continues
        // the progress UI inside Settings.
        let client = LLMClientFactory.shared.client()
        let adapter = LLMClientUIAdapter(client: client)
        adapter.warm()

        // Dismiss + mark setup complete on the next runloop tick so the
        // `disabled` state of the CTA gets the visual beat it needs.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            onComplete()
        }
    }
}
