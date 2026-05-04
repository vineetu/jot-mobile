import SwiftUI

struct ContentView: View {
    @State private var recorder = DualRecorder()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                statusHeader

                recordButton
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .center)

                if let startError {
                    Text(startError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                }

                streamingSection
                finalSection

                Spacer()
            }
            .padding()
            .navigationTitle("Dual Model")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            await recorder.warmUp()
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 10, height: 10)
            Text(recorder.status)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            if recorder.elapsedSeconds > 0, !recorder.isRecording {
                Text(String(format: "%.2fs", recorder.elapsedSeconds))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var statusDotColor: Color {
        if recorder.isRecording { return .red }
        if recorder.bothModelsReady { return .green }
        return .orange
    }

    @State private var startError: String?

    private var recordButton: some View {
        Button {
            Task {
                if recorder.isRecording {
                    await recorder.stop()
                } else {
                    do {
                        startError = nil
                        try await recorder.start()
                    } catch {
                        startError = "Could not start: \(error.localizedDescription)"
                    }
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red : Color.accentColor)
                    .frame(width: 96, height: 96)
                    .opacity(recorder.bothModelsReady ? 1.0 : 0.4)
                Image(systemName: recorder.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .disabled(!recorder.bothModelsReady || recorder.isStopInFlight)
        .accessibilityLabel(recorder.isRecording ? "Stop recording" : "Start recording")
    }

    private var streamingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Streaming · Parakeet EOU 120M @ 320ms")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(recorder.streamingText.isEmpty ? "—" : recorder.streamingText)
                    .font(.body)
                    .italic(recorder.streamingIsVolatile && !recorder.streamingText.isEmpty)
                    .foregroundStyle(recorder.streamingIsVolatile ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 100, maxHeight: 160)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var finalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Final · Parakeet TDT 0.6B v2")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(recorder.finalText.isEmpty ? "—" : recorder.finalText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 120, maxHeight: 220)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

#Preview {
    ContentView()
}
