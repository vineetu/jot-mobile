import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CleanupService.self) private var cleanupService

    @State private var cleanupEnabled: Bool
    @State private var instructions: String

    @AppStorage(
        AppGroup.Keys.keyboardAutoPasteEnabled,
        store: AppGroup.defaults
    )
    private var keyboardAutoPasteEnabled: Bool = true

    init() {
        let loaded = CleanupSettings.load()
        _cleanupEnabled = State(initialValue: loaded.enabled)
        _instructions = State(initialValue: loaded.instructions)
    }

    private let ink = Color(red: 0.06, green: 0.06, blue: 0.07)
    private let amber = Color(red: 1.0, green: 0.72, blue: 0.10)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            ledgerRules.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    statusPanel
                    transcriptionSection
                    keyboardSection
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 40)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private var ledgerRules: some View {
        Canvas { ctx, size in
            let step: CGFloat = 32
            var y: CGFloat = step
            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 0.5)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.035)))
                y += step
            }
        }
        .allowsHitTesting(false)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("JOT CONFIG")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(amber.opacity(0.82))
                Text("Settings")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
            }
            Spacer()
            Button("DONE") {
                dismiss()
            }
            .font(.system(size: 11, weight: .heavy, design: .monospaced))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.82))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.06))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
            )
            .buttonStyle(.plain)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionEyebrow("CLEANUP STATUS")
            HStack(spacing: 12) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(cleanupService.status.displayMessage)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("On-device cleanup via Apple Intelligence")
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.55))
                }
                Spacer()
            }
        }
        .padding(16)
        .background(panelBackground)
    }

    private var transcriptionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionEyebrow("TRANSCRIPTION")
            settingRule
            settingToggleRow(
                title: "Clean up transcription",
                detail: "Rewrite each transcript before it lands in the ledger.",
                isOn: $cleanupEnabled
            )
            .onChange(of: cleanupEnabled) { _, _ in saveSettings() }
            settingRule

            VStack(alignment: .leading, spacing: 10) {
                Text("CLEANUP INSTRUCTIONS")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(.white.opacity(0.6))

                TextEditor(text: $instructions)
                    .font(.body)
                    .foregroundStyle(.white.opacity(cleanupEnabled ? 0.92 : 0.4))
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .background(editorBackground)
                    .disabled(!cleanupEnabled)
                    .onChange(of: instructions) { _, _ in saveSettings() }

                HStack {
                    Spacer()
                    Button("RESET TO DEFAULT") {
                        instructions = CleanupSettings.defaultInstructions
                        saveSettings()
                    }
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(
                        instructions == CleanupSettings.defaultInstructions
                            ? .white.opacity(0.28)
                            : amber.opacity(cleanupEnabled ? 0.88 : 0.35)
                    )
                    .disabled(instructions == CleanupSettings.defaultInstructions || !cleanupEnabled)
                    .buttonStyle(.plain)
                }
            }

            Text("These instructions are sent to Apple Intelligence alongside each transcript. Runs entirely on-device.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyboardSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionEyebrow("KEYBOARD")
            settingRule
            settingToggleRow(
                title: "Auto-paste from keyboard",
                detail: "Insert the latest dictation automatically on first appearance.",
                isOn: $keyboardAutoPasteEnabled
            )
            settingRule
            Text("When enabled, the Jot keyboard inserts the latest dictation automatically on first appearance.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sectionEyebrow(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .heavy, design: .monospaced))
            .tracking(2)
            .foregroundStyle(amber.opacity(0.82))
    }

    private var settingRule: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .frame(height: 0.5)
    }

    private func settingToggleRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .foregroundStyle(.white.opacity(0.92))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(amber)
        }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }

    private var editorBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        cleanupEnabled ? amber.opacity(0.18) : .white.opacity(0.08),
                        lineWidth: 1
                    )
            )
    }

    private var statusSymbol: String {
        switch cleanupService.status {
        case .ready: return "checkmark.circle.fill"
        case .modelDownloading: return "arrow.down.circle.fill"
        case .unavailable: return "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch cleanupService.status {
        case .ready: return .green
        case .modelDownloading: return amber
        case .unavailable: return .orange
        }
    }

    private func saveSettings() {
        CleanupSettings(enabled: cleanupEnabled, instructions: instructions).save()
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environment(CleanupService())
    }
}
