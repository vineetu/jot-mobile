import CoreMLLLM
import CryptoKit
import Foundation

// Embed structural help chunks with the bundled EmbeddingGemma and emit
// Jot/Resources/help-corpus.json, stamped with the embedding modelVersion and a
// sha256 of features.md (the freshness key checked by check-help-corpus-fresh.sh).
//
//   embed <chunks.json> <features.md> <out help-corpus.json>

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write("usage: embed <chunks> <features.md> <out>\n".data(using: .utf8)!)
    exit(2)
}

// modelVersion MUST equal EmbeddingGemmaService.modelVersion in the app, or the
// app disables the help lane on a version-mismatch guard.
let MODEL_VERSION = "embeddinggemma-300m-256"
let MODEL_DIR = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .deletingLastPathComponent()              // scripts/help-corpus
    .deletingLastPathComponent()              // scripts
    .deletingLastPathComponent()              // repo root
    .appendingPathComponent("Jot/Resources/Models/EmbeddingGemma")

struct InChunk: Codable { let text: String; let id: String; let title: String; let anchor: String }
struct OutChunk: Codable { let id: String; let title: String; let anchor: String; let text: String; let vector: [Float] }
struct Bundle: Codable { let modelVersion: String; let sourceHash: String; let chunks: [OutChunk] }

let inChunks = try JSONDecoder().decode([InChunk].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
let featuresData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let sourceHash = SHA256.hash(data: featuresData).map { String(format: "%02x", $0) }.joined()

FileHandle.standardError.write("loading EmbeddingGemma from \(MODEL_DIR.path)…\n".data(using: .utf8)!)
let model = try await EmbeddingGemma.load(bundleURL: MODEL_DIR)

var out: [OutChunk] = []
for (i, c) in inChunks.enumerated() {
    let v = try model.encode(text: c.text, task: .retrievalDocument, dim: 256)
    out.append(OutChunk(id: c.id, title: c.title, anchor: c.anchor, text: c.text, vector: v))
    if (i + 1) % 30 == 0 {
        FileHandle.standardError.write("  embedded \(i + 1)/\(inChunks.count)\n".data(using: .utf8)!)
    }
}

let bundle = Bundle(modelVersion: MODEL_VERSION, sourceHash: sourceHash, chunks: out)
try JSONEncoder().encode(bundle).write(to: URL(fileURLWithPath: args[3]))
FileHandle.standardError.write("wrote \(out.count) chunks, sourceHash=\(sourceHash.prefix(12))…\n".data(using: .utf8)!)
