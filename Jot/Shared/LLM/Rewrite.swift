import FoundationModels

// `@Generable` projects this struct into a JSON schema. Both decoding paths use
// it: Apple Foundation Models drives `LanguageModelSession.respond(...
// generating: Rewrite.self)`, and `mlx-swift-structured` (Phi-4 backend) hands
// the schema to the constrained-decoding sampler so the model literally cannot
// emit preamble like "Here is the rewritten text:" — only valid JSON matching
// this shape. The text payload is the rewritten body and nothing else.
//
// This file is in `Shared/` so it compiles into both the main app and the
// extensions. `FoundationModels` is a system framework available in
// extensions on iOS 26, so import-side it's safe everywhere.
@available(iOS 26.0, *)
@Generable
struct Rewrite: Codable {
    @Guide(description: "The rewritten text only — no preamble, no quotes, no explanation")
    let text: String
}
