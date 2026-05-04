import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        Form {
            Section {
                Text("Jot is built on top of open-source software and open-weight speech recognition models. The authors and licenses are credited below.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            Section {
                AcknowledgementRow(
                    title: "Parakeet TDT 0.6B v2",
                    author: "NVIDIA",
                    license: "Open Model License + cc-by-4.0",
                    url: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml",
                    description: "On-device speech recognition for the final transcript. Runs on the Apple Neural Engine."
                )
            } header: {
                Text("Speech model")
            }

            Section {
                AcknowledgementRow(
                    title: "Parakeet EOU 120M",
                    author: "NVIDIA / FluidInference",
                    license: "cc-by-4.0",
                    url: "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml",
                    description: "Lightweight streaming model for the live transcription preview while you speak."
                )
            } header: {
                Text("Streaming model")
            }

            Section {
                AcknowledgementRow(
                    title: "FluidAudio",
                    author: "FluidInference",
                    license: "Apache 2.0",
                    url: "https://github.com/FluidInference/FluidAudio",
                    description: "Swift SDK that loads the Parakeet models on the Apple Neural Engine."
                )
            } header: {
                Text("Speech recognition SDK")
            }

            Section {
                Text("All speech recognition runs entirely on this iPhone. No audio or transcript data is sent to NVIDIA, FluidInference, or any third party.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .navigationTitle("Acknowledgements")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct AcknowledgementRow: View {
    let title: String
    let author: String
    let license: String
    let url: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(description)
                .font(.callout)
                .foregroundStyle(.primary)
                .padding(.top, 2)
            HStack(spacing: 12) {
                Label(license, systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let link = URL(string: url) {
                    Link(destination: link) {
                        Label("Source", systemImage: "arrow.up.right.square")
                            .font(.caption)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
