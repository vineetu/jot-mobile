import SwiftUI

/// Glass-heavy download-progress banner (Mockup 13 / plan §6.4).
///
/// Pinned to the top of `AIRewriteSettingsView` when the LLM is in
/// `.downloading(fraction:)`. Surfaces the model name, byte progress,
/// rough time-remaining estimate, and a progress bar in coral→red.
///
/// ## Scope
///
/// Per plan §10.6, the banner appears **only** inside `AIRewriteSettingsView`
/// in v1. Making it global across the nav stack would require an app-level
/// coordinator we're explicitly not building.
///
/// ## Cancel API
///
/// The close-X cancels the in-flight download by calling
/// `LLMClientUIAdapter.cancelDownload()` — the same path the in-row Cancel
/// button uses. We do NOT add a new service method.
///
/// ## Time-remaining estimate
///
/// Simple linear extrapolation from a recent (fraction, timestamp) sample.
/// When the velocity is unreliable (fraction not advancing or near-zero
/// progress), the copy falls back to "about a few minutes left" per
/// plan §6.4. The estimate is best-effort and intentionally vague — we'd
/// rather show "a few minutes left" than a precise lie.
struct AIRewriteDownloadBanner: View {

    /// Download fraction in `0...1`. Bound to the adapter's `.downloading`
    /// payload so the bar advances as MLX streams in chunks.
    let fraction: Double

    /// Model display name (e.g. "Phi-4 mini"). Caller passes
    /// `JotDesign.activeRewriteModelDisplayName`.
    let modelDisplayName: String

    /// Fires when the user taps the close-X. Caller wires this to
    /// `LLMClientUIAdapter.cancelDownload()`.
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Sample of (fraction, wall-clock) used to compute a rough velocity
    /// for the time-remaining estimate. Stored as @State so it survives
    /// SwiftUI re-renders, but lives only inside the banner — no shared
    /// state with the adapter or the settings view.
    @State private var lastSample: (fraction: Double, at: Date)?

    /// Cached velocity (fraction per second). Updated only when the
    /// fraction advances by ≥0.5% so noise from frequent updates doesn't
    /// jitter the time-remaining copy.
    @State private var velocityFractionPerSecond: Double = 0

    /// Numeric size for the byte-progress math. Read from the shared
    /// `JotDesign.activeRewriteModelSizeGB` so the banner stays in sync
    /// with the pitch sheet + settings page when the active provider
    /// swaps.
    private static let totalSizeGB: Double = JotDesign.activeRewriteModelSizeGB

    /// Total height target from the mockup. The internal vertical padding
    /// + the sub-strip get us to ~80pt total.
    private static let targetHeight: CGFloat = 80

    var body: some View {
        VStack(spacing: 0) {
            mainRow
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

            progressBar
                .padding(.horizontal, 12)

            subStrip
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(minHeight: Self.targetHeight)
        .background(bannerBackground)
        .overlay(coralBorder)
        .padding(.horizontal, JotDesign.Spacing.pageMargin)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityCopy)
        .onAppear {
            seedSampleIfNeeded()
        }
        .onChange(of: fraction) { _, newFraction in
            updateVelocity(forNewFraction: newFraction)
        }
    }

    // MARK: - Main row (icon + headline + close-X)

    private var mainRow: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBox(
                symbol: "arrow.down.circle.fill",
                tint: Color.jotAccent,
                size: 44
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading \(modelDisplayName)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.jotInk)
                    .lineLimit(1)
                Text(byteAndTimeCopy)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.jotMute)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onCancel()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.jotMute)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.85))
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.jotMuteWeak.opacity(0.30), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel \(modelDisplayName) download")
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            let clamped = max(0, min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.jotMuteWeak.opacity(0.30))
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.jotAccent,
                                Color.jotRecord
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(6, geo.size.width * clamped))
                    .animation(
                        reduceMotion ? nil : .easeOut(duration: 0.25),
                        value: clamped
                    )
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true) // The wrapper's combined label carries this.
    }

    // MARK: - Sub-strip ("You can keep using Jot · We'll notify when ready")

    private var subStrip: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.jotSuccess.opacity(0.75))
            Text("You can keep using Jot")
                .font(.system(size: 11))
                .foregroundStyle(Color.jotMute)
            Text("·")
                .font(.system(size: 11))
                .foregroundStyle(Color.jotMuteWeak)
            Text("We'll notify when ready")
                .font(.system(size: 11))
                .foregroundStyle(Color.jotMute)
            Spacer()
        }
    }

    // MARK: - Background + border

    private var bannerBackground: some View {
        RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
            .fill(Color.white.opacity(0.85))
            .shadow(color: Color.jotAccent.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    private var coralBorder: some View {
        RoundedRectangle(cornerRadius: JotDesign.Spacing.cardRadius, style: .continuous)
            .strokeBorder(Color.jotAccent.opacity(0.55), lineWidth: 1)
    }

    // MARK: - Copy helpers

    /// "0.9 of 2.4 GB · about 2 min left" or the unstable fallback.
    ///
    /// First-paint guard: when the download has barely started (`doneGB`
    /// below 0.05 — i.e. less than ~50 MB in), the "0.0 of 2.4 GB" prefix
    /// reads as broken / stuck. Substitute "starting…" so the banner
    /// signals motion before the byte counter has anything meaningful to
    /// report.
    private var byteAndTimeCopy: String {
        let clamped = max(0, min(1, fraction))
        let doneGB = clamped * Self.totalSizeGB
        let totalStr = String(format: "%.1f", Self.totalSizeGB)
        let time = timeRemainingCopy()

        if doneGB < 0.05 {
            return "starting… · \(time)"
        }

        let doneStr = String(format: "%.1f", doneGB)
        return "\(doneStr) of \(totalStr) GB · \(time)"
    }

    /// Linear-extrapolation time-remaining estimate. Falls back to
    /// "about a few minutes left" when the velocity is unreliable
    /// (zero / near-zero fraction-per-second), per plan §6.4.
    private func timeRemainingCopy() -> String {
        guard velocityFractionPerSecond > 0.00005 else {
            return "about a few minutes left"
        }
        let remainingFraction = max(0, 1 - fraction)
        let seconds = remainingFraction / velocityFractionPerSecond
        guard seconds.isFinite, seconds > 0 else {
            return "about a few minutes left"
        }

        if seconds < 30 {
            return "about a few seconds left"
        }
        if seconds < 90 {
            return "about a minute left"
        }
        let minutes = Int((seconds / 60).rounded())
        return "about \(minutes) min left"
    }

    private var accessibilityCopy: String {
        let pct = Int((fraction * 100).rounded())
        return "Downloading \(modelDisplayName), \(pct) percent. \(byteAndTimeCopy)."
    }

    // MARK: - Velocity tracking

    private func seedSampleIfNeeded() {
        if lastSample == nil {
            lastSample = (fraction: fraction, at: Date())
        }
    }

    /// Update the rolling velocity only when the fraction moves ≥0.5%.
    /// Small movements get ignored so the time-remaining copy doesn't
    /// re-render on every 100ms poll tick. When the fraction goes
    /// backwards (resume from a different chunk size) we just re-seed
    /// the sample without computing a velocity.
    private func updateVelocity(forNewFraction newFraction: Double) {
        let now = Date()
        guard let prev = lastSample else {
            lastSample = (fraction: newFraction, at: now)
            return
        }
        let delta = newFraction - prev.fraction
        if delta < -0.001 {
            // Fraction went backwards — re-seed silently.
            lastSample = (fraction: newFraction, at: now)
            return
        }
        guard delta >= 0.005 else { return }
        let elapsed = now.timeIntervalSince(prev.at)
        guard elapsed > 0 else { return }
        let v = delta / elapsed
        // Light EMA smoothing so single-tick spikes don't dominate.
        if velocityFractionPerSecond == 0 {
            velocityFractionPerSecond = v
        } else {
            velocityFractionPerSecond = 0.6 * velocityFractionPerSecond + 0.4 * v
        }
        lastSample = (fraction: newFraction, at: now)
    }
}

#Preview {
    VStack {
        AIRewriteDownloadBanner(
            fraction: 0.38,
            modelDisplayName: "Phi-4 mini",
            onCancel: {}
        )
        Spacer()
    }
    .background(JotDesign.background.ignoresSafeArea())
}
