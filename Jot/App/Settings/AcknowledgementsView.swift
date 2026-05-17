//
//  AcknowledgementsView.swift
//  Jot
//
//  Open-source attribution surface. Required for App Store submission and
//  for the SIL OFL / Apache-2.0 / MIT / CC-BY license terms shipped in the
//  app bundle.
//
//  Two sections:
//    1. Models + fonts — the on-device speech models, the speech-recognition
//       SDK that loads them, and the Fraunces typeface. These have specific
//       legal terms (CC-BY, OFL, Apache) that ship in the binary so we
//       attribute them with the SDK + license + source link.
//    2. Swift packages — the SPM dependency tree pinned in `Package.resolved`.
//       Names + license + version + GitHub link per row. Versions are
//       hard-coded here (kept in sync with `Package.resolved`) so the
//       acknowledgements page can render without parsing the resolved file
//       at runtime; reviewers should bump this list when bumping SPM pins.
//

import SwiftUI

struct AcknowledgementsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: JotDesign.Spacing.sectionGap) {
                hero

                modelsAndFontsSection
                swiftPackagesSection

                privacyFooter
            }
            .padding(.horizontal, JotDesign.Spacing.pageMargin)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .background(WallpaperBackground())
        .navigationTitle("Acknowledgements")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    // MARK: - Hero copy

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Jot is built on open-source software and open-weight models. The authors and licenses are credited below.")
                .font(.system(size: 15))
                .foregroundStyle(Color.jotPageInkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.top, 4)
    }

    // MARK: - Models + fonts

    private var modelsAndFontsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Models & fonts")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 8) {
                VStack(spacing: 0) {
                    AcknowledgementRow(
                        title: "Parakeet TDT 0.6B v2",
                        author: "NVIDIA",
                        license: "CC-BY 4.0",
                        version: nil,
                        url: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml",
                        showDivider: true
                    )
                    AcknowledgementRow(
                        title: "Parakeet TDT-CTC 110M",
                        author: "NVIDIA",
                        license: "CC-BY 4.0",
                        version: nil,
                        url: "https://huggingface.co/FluidInference/parakeet-tdt-ctc-110m-coreml",
                        showDivider: true
                    )
                    AcknowledgementRow(
                        title: "Parakeet EOU 120M",
                        author: "NVIDIA / FluidInference",
                        license: "NVIDIA Open Model License",
                        version: nil,
                        url: "https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml",
                        showDivider: true
                    )
                    AcknowledgementRow(
                        title: "Qwen 3.5 4B",
                        author: "Alibaba Cloud / Qwen Team",
                        license: "Apache 2.0",
                        version: nil,
                        url: "https://huggingface.co/Qwen/Qwen3.5-4B",
                        showDivider: true
                    )
                    AcknowledgementRow(
                        title: "Phi-4 mini",
                        author: "Microsoft",
                        license: "MIT",
                        version: nil,
                        url: "https://huggingface.co/microsoft/Phi-4-mini-instruct",
                        showDivider: true
                    )
                    AcknowledgementRow(
                        title: "Fraunces",
                        author: "Undercase Type",
                        license: "SIL OFL 1.1",
                        version: nil,
                        url: "https://github.com/googlefonts/fraunces",
                        showDivider: false
                    )
                }
            }
        }
    }

    // MARK: - SPM packages

    /// Hard-coded mirror of `Package.resolved`. Why hard-code: the resolved
    /// file isn't shipped inside the app bundle (it lives in the .xcodeproj),
    /// so we can't read it at runtime. Keep this list in sync when bumping
    /// SPM pins — reviewers should diff this section against
    /// `Jot.xcodeproj/.../Package.resolved` on every dependency change.
    private var swiftPackagesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Swift packages")
                .padding(.horizontal, 4)

            GlassCard(tier: .regular, padding: 8) {
                VStack(spacing: 0) {
                    ForEach(Array(spmPackages.enumerated()), id: \.element.title) { index, pkg in
                        AcknowledgementRow(
                            title: pkg.title,
                            author: pkg.author,
                            license: pkg.license,
                            version: pkg.version,
                            url: pkg.url,
                            showDivider: index < spmPackages.count - 1
                        )
                    }
                }
            }
        }
    }

    private var privacyFooter: some View {
        Text("All speech recognition and AI rewriting runs on this iPhone. No audio or transcript data is sent to NVIDIA, Microsoft, FluidInference, or any third party.")
            .font(.footnote)
            .foregroundStyle(Color.jotMute)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - SPM data

    private struct PackageRow {
        let title: String
        let author: String
        let license: String
        let version: String
        let url: String
    }

    private let spmPackages: [PackageRow] = [
        .init(title: "FluidAudio", author: "FluidInference", license: "Apache 2.0",
              version: "0.13.6",
              url: "https://github.com/FluidInference/FluidAudio"),
        .init(title: "mlx-swift", author: "Apple", license: "MIT",
              version: "0.31.3",
              url: "https://github.com/ml-explore/mlx-swift"),
        .init(title: "mlx-swift-lm", author: "Apple", license: "MIT",
              version: "3.31.3",
              url: "https://github.com/ml-explore/mlx-swift-lm"),
        .init(title: "swift-transformers", author: "Hugging Face", license: "Apache 2.0",
              version: "1.3.1",
              url: "https://github.com/huggingface/swift-transformers"),
        .init(title: "swift-jinja", author: "Hugging Face", license: "MIT",
              version: "2.3.5",
              url: "https://github.com/huggingface/swift-jinja"),
        .init(title: "swift-huggingface", author: "Hugging Face", license: "Apache 2.0",
              version: "0.9.0",
              url: "https://github.com/huggingface/swift-huggingface"),
        .init(title: "yyjson", author: "ibireme", license: "MIT",
              version: "0.12.0",
              url: "https://github.com/ibireme/yyjson"),
        .init(title: "swift-argument-parser", author: "Apple", license: "Apache 2.0",
              version: "1.7.1",
              url: "https://github.com/apple/swift-argument-parser"),
        .init(title: "swift-numerics", author: "Apple", license: "Apache 2.0",
              version: "1.1.1",
              url: "https://github.com/apple/swift-numerics"),
        .init(title: "swift-collections", author: "Apple", license: "Apache 2.0",
              version: "1.4.1",
              url: "https://github.com/apple/swift-collections"),
        .init(title: "swift-atomics", author: "Apple", license: "Apache 2.0",
              version: "1.3.0",
              url: "https://github.com/apple/swift-atomics"),
        .init(title: "swift-async-algorithms", author: "Apple", license: "Apache 2.0",
              version: "1.1.3",
              url: "https://github.com/apple/swift-async-algorithms"),
        .init(title: "swift-asn1", author: "Apple", license: "Apache 2.0",
              version: "1.7.0",
              url: "https://github.com/apple/swift-asn1"),
        .init(title: "swift-crypto", author: "Apple", license: "Apache 2.0",
              version: "4.5.0",
              url: "https://github.com/apple/swift-crypto"),
        .init(title: "swift-nio", author: "Apple", license: "Apache 2.0",
              version: "2.99.0",
              url: "https://github.com/apple/swift-nio"),
        .init(title: "swift-json-schema", author: "Ivan Petrukha", license: "MIT",
              version: "2.0.2",
              url: "https://github.com/petrukha-ivan/swift-json-schema"),
        .init(title: "swift-system", author: "Apple", license: "Apache 2.0",
              version: "1.6.4",
              url: "https://github.com/apple/swift-system"),
        .init(title: "swift-syntax", author: "Apple", license: "Apache 2.0",
              version: "600.0.1",
              url: "https://github.com/swiftlang/swift-syntax"),
        .init(title: "EventSource", author: "Mattt", license: "MIT",
              version: "1.4.1",
              url: "https://github.com/mattt/EventSource"),
    ]
}

// MARK: - Row

/// Single attribution row inside a `GlassCard`. Tapping the row opens the
/// upstream source URL via `Link` — the GitHub / Hugging Face landing page
/// is the canonical place for the full license text, so we link out rather
/// than ship a docblock expander in v1.
private struct AcknowledgementRow: View {
    let title: String
    let author: String
    let license: String
    /// `nil` for non-versioned entries (models, fonts). Renders as the
    /// secondary trailing line when present.
    let version: String?
    let url: String
    let showDivider: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let link = URL(string: url) {
                Link(destination: link) { rowBody }
                    .buttonStyle(.plain)
            } else {
                rowBody
            }

            if showDivider {
                Divider()
                    .overlay(Color.jotMuteWeak.opacity(0.45))
                    .padding(.leading, 12)
            }
        }
    }

    private var rowBody: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.jotInk)
                Text(authorAndLicense)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.jotMute)
                if let version {
                    Text("v\(version)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.jotMuteWeak)
                }
            }

            Spacer(minLength: 8)

            Image(systemName: "arrow.up.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.jotMuteWeak)
                .padding(.top, 4)
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(authorAndLicense)\(version.map { ", version \($0)" } ?? "")")
        .accessibilityHint("Opens source in browser")
    }

    private var authorAndLicense: String {
        "\(author) · \(license)"
    }
}

#Preview {
    NavigationStack {
        AcknowledgementsView()
    }
}
