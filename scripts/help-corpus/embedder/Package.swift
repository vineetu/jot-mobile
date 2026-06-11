// swift-tools-version: 6.0
import PackageDescription

// Build-time embedder for the Ask help corpus. Uses the SAME EmbeddingGemma /
// CoreML-LLM the app ships (pin must match Jot/project.yml's CoreMLLLM version)
// so bundled doc vectors are comparable to runtime query vectors.
let package = Package(
    name: "embed",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/john-rocky/CoreML-LLM", exact: "1.9.0"),
    ],
    targets: [
        .executableTarget(
            name: "embed",
            dependencies: [.product(name: "CoreMLLLM", package: "CoreML-LLM")]),
    ]
)
