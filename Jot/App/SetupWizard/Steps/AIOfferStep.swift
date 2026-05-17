//
//  AIOfferStep.swift
//  Jot
//
//  Phase 6 — wizard panel Optional Step 2 (AI Offer).
//  Coral sparkle IconTile + "Add AI rewrite" + "Download · 2.4 GB" CTA.
//  Wires to `LLMClientUIAdapter.warm()` against
//  `LLMClientFactory.shared.client()`. After the warm is kicked off we
//  dismiss the wizard — continuing download progress is surfaced inline
//  in `AIRewriteSettingsView`'s compact model strip (the legacy top-pinned
//  banner was removed to kill a cold-launch flicker).
//

import SwiftUI

struct AIOfferStep: View {
    let onClose: () -> Void
    let onBack: () -> Void
    let onComplete: () -> Void

    @State private var didKickOff = false
    @State private var kickoffTask: Task<Void, Never>?

    var body: some View {
        WizardPanel(
            header: WizardHeader(style: .optional(current: 1), onClose: onClose, onBack: onBack)
        ) {
            VStack(spacing: 22) {
                Spacer(minLength: 40)

                IconTile(
                    systemImage: "sparkles",
                    tint: JotDesign.JotSemanticIcon.ai,
                    shaded: JotDesign.JotSemanticIcon.aiShaded,
                    size: JotDesign.Spacing.tileHeroSize
                )
                .accessibilityHidden(true)
                .padding(.bottom, 4)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    WizardItalicTitle(text: "Add AI rewrite", size: 30)
                    experimentalChip
                        .alignmentGuide(.firstTextBaseline) { dimensions in
                            dimensions[.firstTextBaseline] + 6
                        }
                }

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
        .onDisappear {
            kickoffTask?.cancel()
            kickoffTask = nil
        }
    }

    private var bodyCopy: String {
        "Polish dictations and convert prose to bullets. \(JotDesign.activeRewriteModelDisplayName) runs on your iPhone — about \(JotDesign.activeRewriteModelSize)."
    }

    private var experimentalChip: some View {
        Text("EXPERIMENTAL")
            .font(.system(size: 10, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(Color.jotCoralBottom)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.jotCoralTop.opacity(0.14))
            .clipShape(Capsule())
    }

    // MARK: - Warm kickoff

    private func kickOffWarm() {
        guard !didKickOff else { return }
        didKickOff = true

        // Kick off Phi-4 (or whichever client the factory returns) via the
        // UI adapter so its `observableStatus` mirror is alive when the
        // user lands on the AI Rewrite settings row. The download itself
        // is long-running (~2.4 GB) and we deliberately don't block the
        // wizard on it — the AI Rewrite settings model strip continues
        // the progress UI (download bar + cancel) inline.
        let client = LLMClientFactory.shared.client()
        let adapter = LLMClientUIAdapter(client: client)
        adapter.warm()

        // Dismiss + mark setup complete on the next runloop tick so the
        // `disabled` state of the CTA gets the visual beat it needs.
        kickoffTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            onComplete()
        }
    }
}
